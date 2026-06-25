#!/usr/bin/env bash
# Forge plugin — macOS single-click installer (v0.1.0)
#
# What this file is:
#   A double-clickable wrapper around install.sh. When opened from Finder,
#   macOS launches Terminal, runs this script, and the installer proceeds
#   end-to-end with the 1Password backend pre-selected. The user is asked
#   for exactly one thing — Touch ID, the first time the 1Password desktop
#   app integrates with the CLI. After that, every subsequent install /
#   re-run / re-heal is zero-prompt.
#
# What single-click does NOT mean here:
#   • Touch ID is OS-enforced for 1Password CLI integration and cannot be
#     scripted around. If the org's secrets backend changes (e.g. GCP
#     Secret Manager), edit BACKEND_FLAGS below.
#   • Homebrew must already be installed (we don't auto-install Homebrew
#     because that's its own curl|bash flow with its own admin password
#     prompt — keeping it out of the auto path means one fewer surprise).
#   • The 1Password vault named below must already contain both items
#     (FORGE_ACCESS_TOKEN, FORGE_PACKAGE_TOKEN). Your Forge operator pre-
#     seeds those for you — if either is missing, the installer prompts
#     for the value at the right step.
#
# Distribution:
#   Ship this file as the only artifact your end-users download. The .sh
#   is fetched fresh from the public installers repo at run time so
#   bugfixes propagate without re-shipping the .command. Override
#   FORGE_INSTALLER_URL in env for testing against a local script.
#
# Gatekeeper note (first-run only):
#   Until this file is signed with an Apple Developer ID + notarized, the
#   first double-click triggers "cannot be opened because it is from an
#   unidentified developer." Workaround: right-click → Open → confirm.
#   macOS then remembers the approval. We'll ship a notarized .pkg in a
#   later cut for the no-warning experience.

set -euo pipefail

# ── Org defaults — edit before distributing to non-BigBrain orgs ─────────────
# OP_VAULT is the 1Password vault name where FORGE_ACCESS_TOKEN and
# FORGE_PACKAGE_TOKEN live as items. The default "Platform - AI - FORGE"
# matches BigBrain's internal vault; other orgs should fork this file and
# substitute their own. Validated against the same regex install.sh uses.
OP_VAULT="${FORGE_OP_VAULT:-Platform - AI - FORGE}"
BACKEND_FLAGS=(--secrets=onepassword --op-vault="$OP_VAULT")

# Where to fetch install.sh from. The default points at the public mirror;
# override with FORGE_INSTALLER_URL=file://$PWD/install.sh during local
# development.
FORGE_INSTALLER_URL="${FORGE_INSTALLER_URL:-https://raw.githubusercontent.com/bigbrainforge/forge-installers/main/install.sh}"
# ─────────────────────────────────────────────────────────────────────────────

# Force CWD to the script's location so any artifacts the installer drops
# (logs, temp files) land somewhere sensible regardless of where Finder
# launched us from. Without this, CWD is $HOME, which gets noisy fast.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

# ANSI color helpers — Terminal.app supports the full set. Falls back to
# plain text if stdout isn't a TTY (e.g. someone bash'd this script from
# inside another wrapper).
if [ -t 1 ]; then
  BOLD=$'\033[1m'
  CYAN=$'\033[1;36m'
  GREEN=$'\033[1;32m'
  YELLOW=$'\033[1;33m'
  RED=$'\033[1;31m'
  RESET=$'\033[0m'
else
  BOLD='' CYAN='' GREEN='' YELLOW='' RED='' RESET=''
fi

# Resize Terminal to something readable. Only fires when run from
# Terminal.app (not iTerm, not VS Code's terminal) — osascript-only, so
# silently no-ops elsewhere.
osascript -e 'tell application "Terminal" to set bounds of front window to {200, 100, 1100, 800}' 2>/dev/null || true

clear || true
cat <<BANNER

  ${BOLD}Forge plugin — macOS installer${RESET}

  This will install:
    ${CYAN}•${RESET} Node.js 24.15.0 (via nvm)
    ${CYAN}•${RESET} 1Password CLI (op) — via Homebrew if not present
    ${CYAN}•${RESET} @bigbrainforge/forge-plugin (latest)
    ${CYAN}•${RESET} Slash commands + hooks + statusline at ~/.claude/

  You may be prompted to:
    ${YELLOW}•${RESET} Touch ID — once, to authorize 1Password CLI integration
    ${YELLOW}•${RESET} Your Mac password — if Homebrew or nvm needs to install

  Secrets backend: ${BOLD}1Password${RESET} (vault: "${OP_VAULT}")
  Installer URL:   ${FORGE_INSTALLER_URL}

BANNER

printf "  Press ${BOLD}Enter${RESET} to begin, or close this window to cancel: "
read -r _ || true

# Pre-flight: bail early on conditions install.sh would die on anyway, so
# the user gets the news up front rather than after Node has finished
# downloading.

if [ "$(uname)" != "Darwin" ]; then
  printf '\n  %s✗ This installer is macOS-only.%s On Linux / Windows, run\n' "$RED" "$RESET"
  printf '    install.sh / install.ps1 directly. See client-install.md.\n\n'
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  printf '\n  %s✗ curl not found.%s This is unusual on macOS — open\n' "$RED" "$RESET"
  printf '    Terminal.app and verify by running:  which curl\n\n'
  exit 1
fi

# Fetch install.sh to a temp file FIRST (not piped to bash). This complies
# with the supply-chain-shield rule (~/.claude/CLAUDE.md): never pipe
# remote content to a shell. The user can inspect $TMP between the fetch
# and the run if they want — we print the path.

TMP=$(mktemp -t forge-install.XXXXXX)
trap 'rm -f "$TMP"' EXIT

printf '\n  %s→%s Fetching installer to %s\n' "$CYAN" "$RESET" "$TMP"

# Handle file:// override for local development. file:// URLs aren't
# supported by curl-without-flags on older versions; we sniff the scheme
# and fall back to cp for the local case.
case "$FORGE_INSTALLER_URL" in
  file://*)
    src=${FORGE_INSTALLER_URL#file://}
    if [ ! -f "$src" ]; then
      printf '  %s✗%s local installer not found: %s\n\n' "$RED" "$RESET" "$src"
      exit 1
    fi
    cp "$src" "$TMP"
    ;;
  http://*|https://*)
    if ! curl -fsSL "$FORGE_INSTALLER_URL" -o "$TMP"; then
      printf '\n  %s✗%s Failed to download installer from %s\n' "$RED" "$RESET" "$FORGE_INSTALLER_URL"
      printf '    Check network / corporate proxy. To inspect:\n'
      printf '      curl -v %s\n\n' "$FORGE_INSTALLER_URL"
      exit 1
    fi
    ;;
  *)
    printf '  %s✗%s unsupported FORGE_INSTALLER_URL scheme: %s\n\n' "$RED" "$RESET" "$FORGE_INSTALLER_URL"
    exit 1
    ;;
esac

chmod +x "$TMP"
printf '  %s✓%s installer downloaded (%s bytes)\n' "$GREEN" "$RESET" "$(wc -c <"$TMP" | tr -d ' ')"

# Pre-launch the 1Password app so Touch ID integration can be approved
# without the user hunting for the app in Finder. Open is a no-op if the
# app is already running.
if [ -d "/Applications/1Password.app" ]; then
  printf '  %s→%s Launching 1Password.app (CLI integration prompt may appear)\n' "$CYAN" "$RESET"
  open -ga "1Password" 2>/dev/null || true
else
  printf '\n  %s!%s 1Password.app not found in /Applications.\n' "$YELLOW" "$RESET"
  printf '    Install from https://1password.com/downloads/mac/ first,\n'
  printf '    or change BACKEND_FLAGS in this script to use a different backend.\n\n'
  exit 1
fi

printf '\n  %s→%s Running install.sh %s\n\n' "$CYAN" "$RESET" "${BACKEND_FLAGS[*]}"
printf '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'

# The actual install. Run with `bash $TMP` (not `$TMP`) so we don't need
# the file's exec bit to survive the temp-dir mount options. Failure
# bubbles out via set -e in install.sh; we catch the exit code below.
installer_exit=0
bash "$TMP" "${BACKEND_FLAGS[@]}" "$@" || installer_exit=$?

printf '\n  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'

if [ "$installer_exit" -eq 0 ]; then
  printf '\n  %s✓ Installation complete.%s\n' "$GREEN" "$RESET"
  printf '\n  Next:\n'
  printf '    1. Open a new Terminal window so FORGE_PACKAGE_TOKEN and\n'
  printf '       FORGE_ACCESS_TOKEN are loaded into the environment.\n'
  printf '    2. Launch Claude Code from that shell.\n'
  printf '    3. Run:  /forge:help\n\n'
else
  printf '\n  %s✗ Installer exited with status %d%s\n' "$RED" "$installer_exit" "$RESET"
  printf '    Re-read the output above for the failing step. Re-running this\n'
  printf '    installer is safe — it is idempotent and will resume / self-heal.\n\n'
fi

# Keep the Terminal window open so the user actually sees the result
# instead of Terminal slamming shut on Process Complete. The read is the
# canonical .command idiom.
printf '  Press %sEnter%s to close this window: ' "$BOLD" "$RESET"
read -r _ || true

exit "$installer_exit"

# forge release: forge-v3.0.5
