#!/usr/bin/env bash
# @bigbrainforge/forge — macOS / Linux installer.
#
# One-command client install. Handles:
#   - nvm install (if missing) + Node 22 LTS
#   - FORGE_PACKAGE_TOKEN storage (OS Keychain or GCP Secret Manager)
#   - ~/.npmrc registry + auth config
#   - npm install -g @bigbrainforge/forge
#   - FORGE_ACCESS_TOKEN storage (same secrets backend)
#   - Shell profile wiring
#   - Smoke test
#
# Usage:
#   ./install.sh                                 # interactive, OS keystore
#   ./install.sh --secrets=gcp --gcp-project=my-proj
#   ./install.sh --secrets=gcp --gcp-project=my-proj \
#                --gcp-package-secret=FORGE_PACKAGE_TOKEN \
#                --gcp-access-secret=FORGE_ACCESS_TOKEN
#
# Re-run is safe — all operations are idempotent.

set -euo pipefail

SCRIPT_VERSION="0.1.0"
NODE_MAJOR=22
PACKAGE_NAME="@bigbrainforge/forge"
REGISTRY_URL="https://npm.pkg.github.com"
REGISTRY_HOST="npm.pkg.github.com"
GCP_PACKAGE_SECRET_DEFAULT="FORGE_PACKAGE_TOKEN"
GCP_ACCESS_SECRET_DEFAULT="FORGE_ACCESS_TOKEN"

# ── Arg parsing ──────────────────────────────────────────────────────────────
# Flags are supported for scripted / CI use. Missing values are prompted for
# interactively so the common path is zero flags.

SECRETS_BACKEND=""
GCP_PROJECT=""
GCP_PACKAGE_SECRET="$GCP_PACKAGE_SECRET_DEFAULT"
GCP_ACCESS_SECRET="$GCP_ACCESS_SECRET_DEFAULT"
SKIP_SMOKE_TEST=false
SKIP_PLUGIN=false
NON_INTERACTIVE=false

usage() {
  cat <<EOF
@bigbrainforge/forge installer (v${SCRIPT_VERSION})

Usage: $0 [options]

Without flags, the installer prompts for the choices it needs. Flags
below are for scripted / CI runs where prompts aren't wanted.

Options:
  --secrets=keystore|gcp          Skip the "where to store secrets" prompt.
                                  keystore = macOS Keychain / Linux libsecret
                                  gcp      = GCP Secret Manager via gcloud
  --gcp-project=PROJECT_ID        Skip the GCP project prompt (used with gcp)
  --gcp-package-secret=NAME       Override the FORGE_PACKAGE_TOKEN secret name
                                  (default: ${GCP_PACKAGE_SECRET_DEFAULT})
  --gcp-access-secret=NAME        Override the access-token secret name
                                  (default: ${GCP_ACCESS_SECRET_DEFAULT})
  --non-interactive               Never prompt — require all needed flags
  --skip-smoke-test               Skip the final 'forge --version' verification
  --skip-plugin                   Skip the Claude Code plugin install step
  -h, --help                      Show this help

For --secrets=gcp, pre-populate the two secrets in your GCP project:
  printf 'ghp_xxx'   | gcloud secrets create ${GCP_PACKAGE_SECRET_DEFAULT}  --data-file=- --project=PROJECT_ID
  printf 'codex-xxx' | gcloud secrets create ${GCP_ACCESS_SECRET_DEFAULT} --data-file=- --project=PROJECT_ID
EOF
}

for arg in "$@"; do
  case "$arg" in
    --secrets=*)          SECRETS_BACKEND="${arg#*=}";;
    --gcp-project=*)      GCP_PROJECT="${arg#*=}";;
    --gcp-package-secret=*)   GCP_PACKAGE_SECRET="${arg#*=}";;
    --gcp-access-secret=*) GCP_ACCESS_SECRET="${arg#*=}";;
    --skip-smoke-test)    SKIP_SMOKE_TEST=true;;
    --skip-plugin)        SKIP_PLUGIN=true;;
    --non-interactive)    NON_INTERACTIVE=true;;
    -h|--help)            usage; exit 0;;
    *)                    printf 'unknown arg: %s\n\n' "$arg" >&2; usage; exit 2;;
  esac
done

if [ -n "$SECRETS_BACKEND" ]; then
  case "$SECRETS_BACKEND" in
    keystore|gcp) ;;
    *) printf 'invalid --secrets=%s (must be keystore or gcp)\n' "$SECRETS_BACKEND" >&2; exit 2;;
  esac
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

step()    { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
info()    { printf '  %s\n' "$*"; }
ok()      { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn()    { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
die()     { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

have()    { command -v "$1" >/dev/null 2>&1; }

# Prompt helpers. Redirect I/O through /dev/tty so prompts work even when
# the installer is piped from curl (`curl | bash` pattern) — though we
# encourage download-then-run for clarity.
prompt_line() {
  # prompt_line "question" "default" → echoes the entered value (or default)
  local question=$1 default=$2 answer
  if [ "$NON_INTERACTIVE" = "true" ]; then
    echo "$default"
    return
  fi
  if [ -n "$default" ]; then
    printf '  %s [%s]: ' "$question" "$default" > /dev/tty
  else
    printf '  %s: ' "$question" > /dev/tty
  fi
  IFS= read -r answer < /dev/tty || answer=""
  [ -z "$answer" ] && answer="$default"
  echo "$answer"
}

prompt_choice() {
  # prompt_choice "question" "default" "option1" "option2" … → echoes chosen value
  local question=$1 default=$2; shift 2
  local i=1 opt choice chosen
  if [ "$NON_INTERACTIVE" = "true" ]; then
    echo "$default"
    return
  fi
  printf '\n  %s\n' "$question" > /dev/tty
  for opt in "$@"; do
    if [ "$opt" = "$default" ]; then
      printf '    [%d] %s  (default)\n' "$i" "$opt" > /dev/tty
    else
      printf '    [%d] %s\n' "$i" "$opt" > /dev/tty
    fi
    i=$((i + 1))
  done
  printf '  > ' > /dev/tty
  IFS= read -r choice < /dev/tty || choice=""
  if [ -z "$choice" ]; then
    echo "$default"
    return
  fi
  case "$choice" in
    ''|*[!0-9]*) echo "$default"; return;;
  esac
  i=1
  for opt in "$@"; do
    if [ "$i" = "$choice" ]; then
      chosen="$opt"
      break
    fi
    i=$((i + 1))
  done
  [ -z "$chosen" ] && chosen="$default"
  echo "$chosen"
}

detect_shell_profile() {
  # Prefer zsh on macOS (default), bash otherwise.
  if [ -n "${ZSH_VERSION:-}" ] || [ "${SHELL##*/}" = "zsh" ]; then
    echo "$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    echo "$HOME/.bashrc"
  else
    echo "$HOME/.profile"
  fi
}

# Append a line to a file only if the line isn't already there.
# Uses grep -F (fixed string) against the whole file to prevent duplicates
# across re-runs.
append_if_missing() {
  local line=$1 file=$2
  [ -f "$file" ] || touch "$file"
  if ! grep -Fqx "$line" "$file"; then
    printf '%s\n' "$line" >> "$file"
    ok "appended to ${file##*/}"
  else
    info "already in ${file##*/} (skipped)"
  fi
}

# ── Step 1: Node 22 via nvm ──────────────────────────────────────────────────

step "Step 1 — Node ${NODE_MAJOR} LTS"

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  info "nvm not found — installing to $NVM_DIR"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"

if ! nvm ls "$NODE_MAJOR" >/dev/null 2>&1; then
  info "installing Node ${NODE_MAJOR} LTS (this may take a minute)"
  nvm install "$NODE_MAJOR" >/dev/null
fi
nvm use "$NODE_MAJOR" >/dev/null
nvm alias default "$NODE_MAJOR" >/dev/null 2>&1 || true
ok "Node $(node --version) active"

PROFILE=$(detect_shell_profile)
append_if_missing 'export NVM_DIR="$HOME/.nvm"' "$PROFILE"
append_if_missing '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' "$PROFILE"

# ── Step 2: choose secrets backend ───────────────────────────────────────────

# Prompt for backend if not supplied via --secrets=...
if [ -z "$SECRETS_BACKEND" ]; then
  SECRETS_BACKEND=$(prompt_choice \
    "Where should the FORGE_PACKAGE_TOKEN and FORGE_ACCESS_TOKEN be stored?" \
    "keystore" \
    "keystore" \
    "gcp")
fi

step "Step 2 — secrets backend: ${SECRETS_BACKEND}"

if [ "$SECRETS_BACKEND" = "gcp" ]; then
  have gcloud || die "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
  gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q '.' \
    || die "gcloud not authenticated. Run: gcloud auth login"
  info "gcloud authenticated as: $(gcloud config get-value account 2>/dev/null)"

  # Prompt for GCP project if not supplied. Use currently-active gcloud
  # project as the default so most users just hit enter.
  if [ -z "$GCP_PROJECT" ]; then
    default_project=$(gcloud config get-value project 2>/dev/null || echo "")
    GCP_PROJECT=$(prompt_line "GCP project ID" "$default_project")
    [ -z "$GCP_PROJECT" ] && die "GCP project ID is required under --secrets=gcp"
  fi

  info "GCP project: ${GCP_PROJECT}"
  info "Package secret:   ${GCP_PACKAGE_SECRET}"
  info "Codex secret: ${GCP_ACCESS_SECRET}"

  # Probe existence of both secrets up front — fail fast if missing.
  for secret in "$GCP_PACKAGE_SECRET" "$GCP_ACCESS_SECRET"; do
    if ! gcloud secrets describe "$secret" --project="$GCP_PROJECT" >/dev/null 2>&1; then
      die "secret '$secret' not found in project '$GCP_PROJECT'. Create it first:
      echo -n '<value>' | gcloud secrets create $secret --data-file=- --project=$GCP_PROJECT"
    fi
    ok "secret '$secret' exists in $GCP_PROJECT"
  done
else
  if ! have security; then
    warn "macOS 'security' command not found — falling back to plain env var (less secure)"
  fi
fi

# ── Step 3: FORGE_PACKAGE_TOKEN ──────────────────────────────────────────────

step "Step 3 — FORGE_PACKAGE_TOKEN → env var"

PAT_VAR=FORGE_PACKAGE_TOKEN

if [ "$SECRETS_BACKEND" = "gcp" ]; then
  # Profile line that fetches from GCP on each shell startup.
  # `2>/dev/null` on the RHS lets a disconnected shell start without failure;
  # npm install will then fail with a clear auth error, which is better UX
  # than the entire shell refusing to open.
  line="export ${PAT_VAR}=\"\$(gcloud secrets versions access latest --secret=${GCP_PACKAGE_SECRET} --project=${GCP_PROJECT} 2>/dev/null)\""
  append_if_missing "$line" "$PROFILE"
  # Populate for the current install session.
  export "${PAT_VAR}"="$(gcloud secrets versions access latest --secret="$GCP_PACKAGE_SECRET" --project="$GCP_PROJECT")"
else
  # Keystore mode — prompt + store in Keychain (macOS) or libsecret (Linux).
  if [ -n "${!PAT_VAR:-}" ]; then
    info "${PAT_VAR} already set in environment — skipping prompt"
  elif have security; then
    if security find-generic-password -s "$PAT_VAR" -a "$USER" -w >/dev/null 2>&1; then
      info "FORGE_PACKAGE_TOKEN already in Keychain — reusing"
    else
      info "paste FORGE_PACKAGE_TOKEN (input hidden; will be stored in Keychain):"
      printf "  FORGE_PACKAGE_TOKEN: "
      stty -echo
      IFS= read -r pat
      stty echo
      printf '\n'
      [ -n "$pat" ] || die "empty FORGE_PACKAGE_TOKEN"
      security add-generic-password -U -s "$PAT_VAR" -a "$USER" -w "$pat"
      ok "stored in Keychain under '$PAT_VAR'"
      unset pat
    fi
    line="export ${PAT_VAR}=\"\$(security find-generic-password -s '${PAT_VAR}' -a \"\$USER\" -w 2>/dev/null)\""
    append_if_missing "$line" "$PROFILE"
    export "${PAT_VAR}"="$(security find-generic-password -s "$PAT_VAR" -a "$USER" -w)"
  elif have secret-tool; then
    # Linux libsecret path
    if ! secret-tool lookup service "$PAT_VAR" >/dev/null 2>&1; then
      info "paste FORGE_PACKAGE_TOKEN (input hidden):"
      secret-tool store --label="FORGE_PACKAGE_TOKEN" service "$PAT_VAR"
      ok "stored in libsecret keyring"
    fi
    line="export ${PAT_VAR}=\"\$(secret-tool lookup service ${PAT_VAR} 2>/dev/null)\""
    append_if_missing "$line" "$PROFILE"
    export "${PAT_VAR}"="$(secret-tool lookup service "$PAT_VAR")"
  else
    die "no keystore found (tried: security, secret-tool). Install one, or re-run with --secrets=gcp"
  fi
fi

[ -n "${!PAT_VAR:-}" ] || die "${PAT_VAR} empty after setup — check keystore/GCP configuration"
ok "${PAT_VAR} populated in current shell (length=${#FORGE_PACKAGE_TOKEN})"

# ── Step 4: ~/.npmrc ─────────────────────────────────────────────────────────

step "Step 4 — ~/.npmrc registry + auth"

NPMRC="$HOME/.npmrc"
append_if_missing "@bigbrainforge:registry=${REGISTRY_URL}" "$NPMRC"
append_if_missing "//${REGISTRY_HOST}/:_authToken=\${${PAT_VAR}}" "$NPMRC"
append_if_missing "always-auth=true" "$NPMRC"

# ── Step 5: npm install ──────────────────────────────────────────────────────

step "Step 5 — install ${PACKAGE_NAME}"
info "(this downloads ~9 MB compressed + tree-sitter grammar prebuilds)"
npm install -g "$PACKAGE_NAME" --no-audit --no-fund
ok "installed $(npm ls -g --depth=0 "$PACKAGE_NAME" 2>/dev/null | grep forge-cli || echo "")"

# ── Step 6: FORGE_ACCESS_TOKEN ────────────────────────────────────────────────

step "Step 6 — FORGE_ACCESS_TOKEN → env var"

TOK_VAR=FORGE_ACCESS_TOKEN

if [ "$SECRETS_BACKEND" = "gcp" ]; then
  line="export ${TOK_VAR}=\"\$(gcloud secrets versions access latest --secret=${GCP_ACCESS_SECRET} --project=${GCP_PROJECT} 2>/dev/null)\""
  append_if_missing "$line" "$PROFILE"
  export "${TOK_VAR}"="$(gcloud secrets versions access latest --secret="$GCP_ACCESS_SECRET" --project="$GCP_PROJECT")"
else
  # Delegate to shield's existing command, which already handles the prompt +
  # Keychain + profile emission. Run it only if the token isn't already there.
  if have security && security find-generic-password -s "$TOK_VAR" -a "$USER" -w >/dev/null 2>&1; then
    info "token already in Keychain — reusing"
    line="export ${TOK_VAR}=\"\$(security find-generic-password -s '${TOK_VAR}' -a \"\$USER\" -w 2>/dev/null)\""
    append_if_missing "$line" "$PROFILE"
    export "${TOK_VAR}"="$(security find-generic-password -s "$TOK_VAR" -a "$USER" -w)"
  else
    info "running 'forge shield fix shell-secret ${TOK_VAR}' (prompt follows)"
    forge shield fix shell-secret "$TOK_VAR" || die "shield fix shell-secret failed"
    # shield emits the profile line itself; we just need to make sure the
    # current shell has the value for the smoke test.
    if have security; then
      export "${TOK_VAR}"="$(security find-generic-password -s "$TOK_VAR" -a "$USER" -w 2>/dev/null || echo '')"
    fi
  fi
fi

[ -n "${!TOK_VAR:-}" ] || warn "${TOK_VAR} not populated in this shell (will be in new shells after profile reload)"

# ── Step 7: install Claude Code plugin (slash commands + statusline) ─────────

step "Step 7 — Claude Code plugin → ~/.claude/"

if [ "${SKIP_PLUGIN:-false}" = "true" ]; then
  info "skipped (--skip-plugin)"
else
  # forge-plugin ships bundled inside @bigbrainforge/forge. Running the
  # published `forge-plugin` bin copies slash commands + statusline hook
  # into ~/.claude/. Safe to re-run (installer is idempotent).
  if have forge-plugin; then
    forge-plugin || warn "forge-plugin install exited with non-zero status"
    ok "plugin installed to ~/.claude/"
  else
    warn "forge-plugin binary not on PATH. Run manually: forge-plugin"
  fi
fi

# ── Step 8: smoke test ───────────────────────────────────────────────────────

if [ "$SKIP_SMOKE_TEST" = "true" ]; then
  step "Step 8 — smoke test (skipped by flag)"
else
  step "Step 8 — smoke test"
  forge --version || die "forge --version failed — install did not succeed"
  ok "forge $(forge --version) is on PATH"
  forge codex --help >/dev/null || die "forge codex --help failed"
  ok "codex subcommand loads cleanly"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

cat <<EOF

$(printf '\033[1;32m✓ forge installed successfully.\033[0m')

  Profile updated: $PROFILE
  Open a new shell (or 'source $PROFILE') to pick up the env vars.

  Next:
    forge --help                                    # top-level usage
    forge codex index --csharp-root <path>          # index a codebase
    forge codex index --csharp-root <path> --push <mcp-url> --repo-id <id>

  Troubleshooting: see docs/client-install.md in the forge-cli package, or
  re-run this installer — it's idempotent.
EOF
