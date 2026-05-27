#!/usr/bin/env bash
# Forge plugin — basic macOS installer, no 1Password (v0.1.0)
#
# For users whose Forge operator hands them the two tokens directly,
# out-of-band, rather than through a shared 1Password vault. The tokens
# are stored in the macOS Keychain via the `security` CLI; the user is
# prompted to paste each value once, with input hidden via stty -echo.
# After install, every new shell pulls the tokens from Keychain on
# startup — no 1Password app, no `op` CLI, no direnv, no vault probe.
#
# How to use:
#   1. Receive both tokens from your Forge operator out-of-band:
#         FORGE_PACKAGE_TOKEN  — GitHub Packages read-access PAT
#         FORGE_ACCESS_TOKEN   — Forge MCP endpoint bearer token
#      Keep them handy — you will paste each one once during install.
#   2. Open Terminal, cd into any directory.
#   3. Run:  bash install-basic.sh
#   4. When prompted, paste FORGE_PACKAGE_TOKEN, press Enter.
#      Input is hidden (no echo) — the value goes straight to Keychain.
#   5. When prompted, paste FORGE_ACCESS_TOKEN, press Enter.
#   6. Done. Open a new Terminal so the profile lines load, then launch
#      Claude Code from that shell.
#
# What it installs (idempotent — safe to re-run):
#   • Node.js 24.15.0 (via nvm)
#   • @bigbrainforge/forge-plugin (latest)
#   • Two entries in the macOS Keychain (under your user account)
#   • Shell-profile lines (~/.zshrc) that re-read both tokens from
#     Keychain on every shell startup
#
# What it does NOT install (use install-tag.sh or install.sh for those):
#   • 1Password CLI (op)
#   • direnv
#   • .envrc per-project files
#
# If you later want to switch to the 1Password backend, run install-tag.sh
# (TAG) or install.sh --secrets=onepassword (general). The two backends
# don't conflict, but only one should be active at a time — the base
# installer sweeps stale Keychain entries when 1Password is selected, and
# vice-versa would need a manual cleanup.

set -euo pipefail

# Override for local development: FORGE_INSTALLER_URL=file://$PWD/install.sh
FORGE_INSTALLER_URL="${FORGE_INSTALLER_URL:-https://raw.githubusercontent.com/bigbrainforge/forge-installers/main/install.sh}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

# ANSI colors — same palette as install.sh.
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

clear || true
cat <<BANNER

  ${BOLD}Forge plugin — basic installer (no 1Password)${RESET}

  This will install (globally, idempotent):
    ${CYAN}•${RESET} Node.js 24.15.0 (via nvm)
    ${CYAN}•${RESET} @bigbrainforge/forge-plugin (latest)
    ${CYAN}•${RESET} Two entries in macOS Keychain (FORGE_PACKAGE_TOKEN, FORGE_ACCESS_TOKEN)

  You will be prompted to:
    ${YELLOW}•${RESET} Paste FORGE_PACKAGE_TOKEN (input hidden, stored in Keychain)
    ${YELLOW}•${RESET} Paste FORGE_ACCESS_TOKEN  (input hidden, stored in Keychain)
    ${YELLOW}•${RESET} Possibly enter your Mac password if nvm needs to install

  Have both tokens ready before continuing. Your Forge operator sent
  them to you out-of-band.

BANNER

printf "  Press ${BOLD}Enter${RESET} to begin, or close this window to cancel: "
read -r _ || true

# Pre-flight: hard checks.
if [ "$(uname)" != "Darwin" ]; then
  printf '\n  %s✗%s macOS only. Linux / Windows users: run install.sh /\n' "$RED" "$RESET"
  printf '    install.ps1 from the public installers repo directly.\n\n'
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  printf '\n  %s✗%s curl not found (unexpected on macOS).\n\n' "$RED" "$RESET"
  exit 1
fi

# Fetch install.sh to a tempfile (NOT curl|bash — supply-chain-shield rule).
TMP=$(mktemp -t forge-install.XXXXXX)
trap 'rm -f "$TMP"' EXIT

printf '\n  %s→%s Fetching installer from %s\n' "$CYAN" "$RESET" "$FORGE_INSTALLER_URL"

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

printf '\n  %s→%s Running install.sh --secrets=keystore\n\n' "$CYAN" "$RESET"
printf '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'

installer_exit=0
bash "$TMP" --secrets=keystore "$@" || installer_exit=$?

printf '\n  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'

if [ "$installer_exit" -eq 0 ]; then
  printf '\n  %s✓ Installation complete.%s\n' "$GREEN" "$RESET"
  printf '\n  Next:\n'
  printf '    1. Open a new Terminal window so the Keychain-reading\n'
  printf '       profile lines load and FORGE_*_TOKEN are populated.\n'
  printf '    2. Verify both tokens loaded:\n'
  printf '         echo "pkg=${BOLD}\${#FORGE_PACKAGE_TOKEN}${RESET} access=${BOLD}\${#FORGE_ACCESS_TOKEN}${RESET}"\n'
  printf '       Both lengths should be non-zero.\n'
  printf '    3. Launch Claude Code from that shell.\n'
  printf '    4. Run:  /forge:help\n\n'
else
  printf '\n  %s✗ Installer exited with status %d%s\n' "$RED" "$installer_exit" "$RESET"
  printf '    Re-read the output above for the failing step. Re-running this\n'
  printf '    installer is safe — it is idempotent and will resume / self-heal.\n\n'
fi

exit "$installer_exit"

# forge release: forge-v2.28.1
