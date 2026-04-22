#!/usr/bin/env bash
# @bigbrainforge/forge-plugin — macOS / Linux installer.
#
# One-command client install for the Claude Code plugin. Handles:
#   - nvm install (if missing) + Node 22 LTS
#   - FORGE_PACKAGE_TOKEN storage (OS Keychain or GCP Secret Manager)
#   - ~/.npmrc registry + auth config
#   - npm install -g @bigbrainforge/forge-plugin
#   - FORGE_ACCESS_TOKEN storage (same secrets backend)
#   - Shell profile wiring
#   - forge-plugin run (copies slash commands + statusline into ~/.claude/)
#   - Plugin-file verification
#
# The plugin is a standalone artifact — it runs against the deployed Forge
# MCP server and does not require the `forge` CLI, codex, or shield to be
# installed locally. Claude Code must already be installed.
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

SCRIPT_VERSION="0.2.0"
NODE_MAJOR=22
PACKAGE_NAME="@bigbrainforge/forge-plugin"
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
SKIP_VERIFY=false
NON_INTERACTIVE=false

usage() {
  cat <<EOF
@bigbrainforge/forge-plugin installer (v${SCRIPT_VERSION})

Installs the Forge Claude Code plugin. Assumes Claude Code is already
installed and that a Forge MCP endpoint has been provisioned for you.

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
  --skip-verify                   Skip the final plugin-file verification
  -h, --help                      Show this help

For --secrets=gcp, pre-populate the two secrets in your GCP project:
  printf 'ghp_xxx'   | gcloud secrets create ${GCP_PACKAGE_SECRET_DEFAULT}  --data-file=- --project=PROJECT_ID
  printf 'mcp-xxx'   | gcloud secrets create ${GCP_ACCESS_SECRET_DEFAULT} --data-file=- --project=PROJECT_ID
EOF
}

for arg in "$@"; do
  case "$arg" in
    --secrets=*)          SECRETS_BACKEND="${arg#*=}";;
    --gcp-project=*)      GCP_PROJECT="${arg#*=}";;
    --gcp-package-secret=*)   GCP_PACKAGE_SECRET="${arg#*=}";;
    --gcp-access-secret=*) GCP_ACCESS_SECRET="${arg#*=}";;
    --skip-verify)        SKIP_VERIFY=true;;
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

# Store a token in the OS keystore (macOS Keychain or Linux libsecret) and
# emit the profile line that reads it at shell startup. Reused for both
# FORGE_PACKAGE_TOKEN (step 3) and FORGE_ACCESS_TOKEN (step 6).
#
# Args: $1 = env-var name (also the keystore target name)
#       $2 = human-readable label for prompts
#
# Behavior:
#   - If the env var is already populated in the current shell, skip prompt.
#   - Else if the keystore already has the entry, reuse it silently.
#   - Else prompt (no-echo), store, and emit profile line.
#
# Exports the env var into the current shell so downstream steps see the value.
store_token_in_keystore() {
  local var_name=$1 label=${2:-$1}
  local val
  val=$(printenv "$var_name" || true)
  if [ -n "$val" ]; then
    info "${var_name} already set in environment — skipping prompt"
    return 0
  fi

  if have security; then
    if security find-generic-password -s "$var_name" -a "$USER" -w >/dev/null 2>&1; then
      info "${var_name} already in Keychain — reusing"
    else
      info "paste ${label} (input hidden; will be stored in Keychain):"
      printf "  %s: " "$var_name"
      stty -echo
      IFS= read -r val
      stty echo
      printf '\n'
      [ -n "$val" ] || die "empty ${var_name}"
      security add-generic-password -U -s "$var_name" -a "$USER" -w "$val"
      ok "stored in Keychain under '$var_name'"
      unset val
    fi
    local line="export ${var_name}=\"\$(security find-generic-password -s '${var_name}' -a \"\$USER\" -w 2>/dev/null)\""
    append_if_missing "$line" "$PROFILE"
    export "${var_name}"="$(security find-generic-password -s "$var_name" -a "$USER" -w)"
  elif have secret-tool; then
    # Linux libsecret path
    if ! secret-tool lookup service "$var_name" >/dev/null 2>&1; then
      info "paste ${label} (input hidden):"
      secret-tool store --label="${label}" service "$var_name"
      ok "stored in libsecret keyring"
    else
      info "${var_name} already in libsecret — reusing"
    fi
    local line="export ${var_name}=\"\$(secret-tool lookup service ${var_name} 2>/dev/null)\""
    append_if_missing "$line" "$PROFILE"
    export "${var_name}"="$(secret-tool lookup service "$var_name")"
  else
    die "no keystore found (tried: security, secret-tool). Install one, or re-run with --secrets=gcp"
  fi
}

# Emit the shell-profile line that reads a token from GCP Secret Manager at
# shell startup, and populate the env var for the current session. Reused
# for both tokens under --secrets=gcp.
store_token_in_gcp() {
  local var_name=$1 gcp_secret=$2
  # Profile line: 2>/dev/null on the RHS lets a disconnected shell start
  # without failure; npm install / plugin runtime will then fail with a
  # clear auth error, which is better UX than the entire shell refusing
  # to open.
  local line="export ${var_name}=\"\$(gcloud secrets versions access latest --secret=${gcp_secret} --project=${GCP_PROJECT} 2>/dev/null)\""
  append_if_missing "$line" "$PROFILE"
  export "${var_name}"="$(gcloud secrets versions access latest --secret="$gcp_secret" --project="$GCP_PROJECT")"
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

  info "GCP project:   ${GCP_PROJECT}"
  info "Package secret: ${GCP_PACKAGE_SECRET}"
  info "Access secret:  ${GCP_ACCESS_SECRET}"

  # Probe existence of both secrets up front — fail fast if missing.
  for secret in "$GCP_PACKAGE_SECRET" "$GCP_ACCESS_SECRET"; do
    if ! gcloud secrets describe "$secret" --project="$GCP_PROJECT" >/dev/null 2>&1; then
      die "secret '$secret' not found in project '$GCP_PROJECT'. Create it first:
      echo -n '<value>' | gcloud secrets create $secret --data-file=- --project=$GCP_PROJECT"
    fi
    ok "secret '$secret' exists in $GCP_PROJECT"
  done
else
  if ! have security && ! have secret-tool; then
    die "no keystore found (tried: security, secret-tool). Install libsecret-tools or re-run with --secrets=gcp"
  fi
fi

# ── Step 3: FORGE_PACKAGE_TOKEN ──────────────────────────────────────────────

step "Step 3 — FORGE_PACKAGE_TOKEN → env var"

if [ "$SECRETS_BACKEND" = "gcp" ]; then
  store_token_in_gcp "FORGE_PACKAGE_TOKEN" "$GCP_PACKAGE_SECRET"
else
  store_token_in_keystore "FORGE_PACKAGE_TOKEN" "FORGE_PACKAGE_TOKEN (GitHub Packages read-access)"
fi

[ -n "${FORGE_PACKAGE_TOKEN:-}" ] || die "FORGE_PACKAGE_TOKEN empty after setup — check keystore/GCP configuration"
ok "FORGE_PACKAGE_TOKEN populated in current shell (length=${#FORGE_PACKAGE_TOKEN})"

# ── Step 4: ~/.npmrc ─────────────────────────────────────────────────────────

step "Step 4 — ~/.npmrc registry + auth"

NPMRC="$HOME/.npmrc"
append_if_missing "@bigbrainforge:registry=${REGISTRY_URL}" "$NPMRC"
append_if_missing "//${REGISTRY_HOST}/:_authToken=\${FORGE_PACKAGE_TOKEN}" "$NPMRC"
append_if_missing "always-auth=true" "$NPMRC"

# ── Step 5: npm install ──────────────────────────────────────────────────────

step "Step 5 — install ${PACKAGE_NAME}"
npm install -g "$PACKAGE_NAME" --no-audit --no-fund
ok "installed ${PACKAGE_NAME}"

# ── Step 6: FORGE_ACCESS_TOKEN ────────────────────────────────────────────────

step "Step 6 — FORGE_ACCESS_TOKEN → env var"

if [ "$SECRETS_BACKEND" = "gcp" ]; then
  store_token_in_gcp "FORGE_ACCESS_TOKEN" "$GCP_ACCESS_SECRET"
else
  store_token_in_keystore "FORGE_ACCESS_TOKEN" "FORGE_ACCESS_TOKEN (Forge MCP endpoint)"
fi

[ -n "${FORGE_ACCESS_TOKEN:-}" ] || warn "FORGE_ACCESS_TOKEN not populated in this shell (will be in new shells after profile reload)"

# ── Step 7: run forge-plugin ─────────────────────────────────────────────────
# Copies slash commands, hooks, statusline, and utility scripts into
# ~/.claude/. Also registers the MCP server with Claude Code's config.

step "Step 7 — Claude Code plugin → ~/.claude/"

if have forge-plugin; then
  forge-plugin || die "forge-plugin install exited with non-zero status"
  ok "plugin installed to ~/.claude/"
else
  die "forge-plugin binary not on PATH after npm install. Check: npm config get prefix"
fi

# ── Step 8: verify plugin files ──────────────────────────────────────────────

if [ "$SKIP_VERIFY" = "true" ]; then
  step "Step 8 — verify (skipped by flag)"
else
  step "Step 8 — verify"
  if [ ! -f "$HOME/.claude/commands/forge/new.md" ]; then
    die "~/.claude/commands/forge/new.md missing — plugin install did not complete"
  fi
  ok "slash commands installed at ~/.claude/commands/forge/"
  if [ ! -f "$HOME/.claude/forge/VERSION" ]; then
    die "~/.claude/forge/VERSION missing — plugin install did not complete"
  fi
  ok "plugin VERSION: $(cat "$HOME/.claude/forge/VERSION")"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

cat <<EOF

$(printf '\033[1;32m✓ Forge plugin installed successfully.\033[0m')

  Profile updated: $PROFILE
  Open a new shell (or 'source $PROFILE') to pick up the env vars.

  Next:
    1. Restart Claude Code so the plugin's slash commands and statusline load.
    2. In Claude Code, run:  /forge:help
    3. Start your first session:  /forge:new

  The plugin runs against your Forge MCP endpoint. No local CLI needed —
  codex indexing is handled centrally by the Forge team.

  Troubleshooting: see client-install.md, or re-run this installer — it's
  idempotent.
EOF
