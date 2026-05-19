#!/usr/bin/env bash
# @bigbrainforge/forge-plugin — macOS / Linux installer.
#
# One-command client install for the Claude Code plugin. Handles:
#   - nvm install (if missing) + Node 22 LTS
#   - FORGE_PACKAGE_TOKEN storage (OS Keychain, GCP Secret Manager, or 1Password)
#   - ~/.npmrc registry + auth config
#   - npm install -g @bigbrainforge/forge-plugin
#   - FORGE_ACCESS_TOKEN storage (same secrets backend)
#   - Shell profile wiring
#   - forge-plugin run (copies slash commands + statusline into ~/.claude/)
#   - Plugin-file verification
#
# The plugin is a standalone artifact — it runs against the deployed Forge
# MCP server and does not require the `forge` CLI, atlas, or shield to be
# installed locally. Claude Code must already be installed.
#
# Usage:
#   ./install.sh                                 # interactive, OS keystore
#   ./install.sh --secrets=gcp --gcp-project=my-proj
#   ./install.sh --secrets=gcp --gcp-project=my-proj \
#                --gcp-package-secret=FORGE_PACKAGE_TOKEN \
#                --gcp-access-secret=FORGE_ACCESS_TOKEN
#   ./install.sh --secrets=onepassword
#   ./install.sh --secrets=onepassword --op-vault="Platform - AI - FORGE" \
#                --op-package-item=FORGE_PACKAGE_TOKEN \
#                --op-access-item=FORGE_ACCESS_TOKEN
#
# Re-run is safe — all operations are idempotent.

set -euo pipefail

SCRIPT_VERSION="0.3.0"
# Exact patch pin — same version on dev box, CI, and clients. Eliminates the
# "works locally, fails on CI" class of drift caused by major-only pins
# picking different patches. Bump in lockstep with .nvmrc and CI workflows.
NODE_VERSION="22.22.2"
PACKAGE_NAME="@bigbrainforge/forge-plugin"
REGISTRY_URL="https://npm.pkg.github.com"
REGISTRY_HOST="npm.pkg.github.com"
GCP_PACKAGE_SECRET_DEFAULT="FORGE_PACKAGE_TOKEN"
GCP_ACCESS_SECRET_DEFAULT="FORGE_ACCESS_TOKEN"
OP_VAULT_DEFAULT="Platform - AI - FORGE"
OP_ACCESS_ITEM_DEFAULT="FORGE_ACCESS_TOKEN"
OP_PACKAGE_ITEM_DEFAULT="FORGE_PACKAGE_TOKEN"
OP_FIELD_DEFAULT="credential"

# ── Arg parsing ──────────────────────────────────────────────────────────────
# Flags are supported for scripted / CI use. Missing values are prompted for
# interactively so the common path is zero flags.

SECRETS_BACKEND=""
GCP_PROJECT=""
GCP_PACKAGE_SECRET="$GCP_PACKAGE_SECRET_DEFAULT"
GCP_ACCESS_SECRET="$GCP_ACCESS_SECRET_DEFAULT"
OP_VAULT="$OP_VAULT_DEFAULT"
OP_ACCESS_ITEM="$OP_ACCESS_ITEM_DEFAULT"
OP_PACKAGE_ITEM="$OP_PACKAGE_ITEM_DEFAULT"
OP_FIELD="$OP_FIELD_DEFAULT"
SKIP_VERIFY=false
NON_INTERACTIVE=false
FORCE_TOKENS=false

usage() {
  cat <<EOF
@bigbrainforge/forge-plugin installer (v${SCRIPT_VERSION})

Installs the Forge Claude Code plugin. Assumes Claude Code is already
installed and that a Forge MCP endpoint has been provisioned for you.

Usage: $0 [options]

Without flags, the installer prompts for the choices it needs. Flags
below are for scripted / CI runs where prompts aren't wanted.

Options:
  --secrets=keystore|gcp|onepassword
                                  Skip the "where to store secrets" prompt.
                                  keystore    = macOS Keychain / Linux libsecret
                                  gcp         = GCP Secret Manager via gcloud
                                  onepassword = 1Password vault via op CLI
  --gcp-project=PROJECT_ID        Skip the GCP project prompt (used with gcp)
  --gcp-package-secret=NAME       Override the FORGE_PACKAGE_TOKEN secret name
                                  (default: ${GCP_PACKAGE_SECRET_DEFAULT})
  --gcp-access-secret=NAME        Override the access-token secret name
                                  (default: ${GCP_ACCESS_SECRET_DEFAULT})
  --op-vault=NAME                 1Password vault name (used with onepassword)
                                  (default: ${OP_VAULT_DEFAULT})
  --op-access-item=NAME           Override the FORGE_ACCESS_TOKEN item name
                                  (default: ${OP_ACCESS_ITEM_DEFAULT})
  --op-package-item=NAME          Override the FORGE_PACKAGE_TOKEN item name
                                  (default: ${OP_PACKAGE_ITEM_DEFAULT})
  --op-field=NAME                 1Password field name on each item
                                  (default: ${OP_FIELD_DEFAULT})
  --non-interactive               Never prompt — require all needed flags
  --skip-verify                   Skip the final plugin-file verification
  --force-tokens                  Force fresh token prompts even if existing
                                  tokens are detected in keystore / GCP /
                                  1Password (for rotation, or when stored
                                  tokens are bad)
  -h, --help                      Show this help

For --secrets=gcp, pre-populate the two secrets in your GCP project:
  printf 'ghp_xxx'   | gcloud secrets create ${GCP_PACKAGE_SECRET_DEFAULT}  --data-file=- --project=PROJECT_ID
  printf 'mcp-xxx'   | gcloud secrets create ${GCP_ACCESS_SECRET_DEFAULT} --data-file=- --project=PROJECT_ID

For --secrets=onepassword, pre-populate the two items in your 1Password vault:
  op item create --category=password --vault="${OP_VAULT_DEFAULT}" \\
    --title="${OP_PACKAGE_ITEM_DEFAULT}" ${OP_FIELD_DEFAULT}='ghp_xxx'
  op item create --category=password --vault="${OP_VAULT_DEFAULT}" \\
    --title="${OP_ACCESS_ITEM_DEFAULT}"  ${OP_FIELD_DEFAULT}='mcp-xxx'

On macOS, the installer offers to auto-install the 1Password CLI via
Homebrew (brew install --cask 1password-cli) if op is missing. Linux
hosts must install op manually:
  https://developer.1password.com/docs/cli/get-started/

The 1Password desktop app must be running and have CLI integration
enabled (Settings → Developer → "Integrate with 1Password CLI") so
op read can resolve items without a session token prompt.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --secrets=*)          SECRETS_BACKEND="${arg#*=}";;
    --gcp-project=*)      GCP_PROJECT="${arg#*=}";;
    --gcp-package-secret=*)   GCP_PACKAGE_SECRET="${arg#*=}";;
    --gcp-access-secret=*) GCP_ACCESS_SECRET="${arg#*=}";;
    --op-vault=*)         OP_VAULT="${arg#*=}";;
    --op-access-item=*)   OP_ACCESS_ITEM="${arg#*=}";;
    --op-package-item=*)  OP_PACKAGE_ITEM="${arg#*=}";;
    --op-field=*)         OP_FIELD="${arg#*=}";;
    --skip-verify)        SKIP_VERIFY=true;;
    --non-interactive)    NON_INTERACTIVE=true;;
    --force-tokens)       FORCE_TOKENS=true;;
    -h|--help)            usage; exit 0;;
    *)                    printf 'unknown arg: %s\n\n' "$arg" >&2; usage; exit 2;;
  esac
done

if [ -n "$SECRETS_BACKEND" ]; then
  case "$SECRETS_BACKEND" in
    keystore|gcp|onepassword) ;;
    *) printf 'invalid --secrets=%s (must be keystore, gcp, or onepassword)\n' "$SECRETS_BACKEND" >&2; exit 2;;
  esac
fi

# ── Auto-detect non-interactive context (no controlling TTY) ─────────────────
#
# When the installer runs through an agent shell (Claude Code, CI without a
# pseudo-TTY, `bash <script.sh` redirected stdin), `/dev/tty` is not writable.
# The prompt helpers below redirect through /dev/tty for `curl | bash`
# compatibility — but if the device is unusable, every prompt would flood
# stderr with `/dev/tty: Device not configured` (macOS) or `No such device or
# address` (Linux) before falling back to the empty default. Detect that case
# once at startup and auto-engage NON_INTERACTIVE so the prompts use defaults
# silently. Users running through an agent must supply all needed values via
# flags; the helpers below already enforce "required value missing" with a
# clear `die` (e.g. --gcp-project under --secrets=gcp).
if [ "$NON_INTERACTIVE" = "false" ]; then
  if ! { : > /dev/tty; } 2>/dev/null; then
    NON_INTERACTIVE=true
    printf '\n  \033[1;36mNo controlling TTY detected (agent shell, CI without -t, or\n'
    printf '  redirected stdin) — auto-engaging --non-interactive. Defaults will\n'
    printf '  be used for every prompt. If the script aborts below for a missing\n'
    printf '  required value, re-run in a real terminal OR pass that value as a\n'
    printf '  flag (see --help).\033[0m\n'
  fi
fi

# ── Validate OP_* inputs (shell-injection guard) ─────────────────────────────
#
# The four --op-* values are interpolated into a literal `op read "op://..."`
# line that is appended to $PROFILE / ~/.zshrc / ~/.bashrc and re-executed at
# every shell startup forever. Any shell metacharacter in a vault / item /
# field name would inject persistent code into that line. Real-world
# 1Password vault / item / field names are alphanumeric + space + . _ -.
# Reject anything else loudly at parse time, before store_token_in_onepassword
# is ever called.
#
# Matches the ps1 ValidatePattern attribute on $OpVault / $OpAccessItem /
# $OpPackageItem / $OpField.

op_name_valid() {
  # Returns 0 if $1 matches ^[A-Za-z0-9 ._-]+$, else 1. POSIX-portable case
  # with a negated bracket expression — works on busybox, dash, ash, bash.
  case "$1" in
    '') return 1;;
    *[!A-Za-z0-9\ ._-]*) return 1;;
    *) return 0;;
  esac
}

for op_pair in "OP_VAULT:$OP_VAULT" "OP_ACCESS_ITEM:$OP_ACCESS_ITEM" "OP_PACKAGE_ITEM:$OP_PACKAGE_ITEM" "OP_FIELD:$OP_FIELD"; do
  op_name="${op_pair%%:*}"
  op_value="${op_pair#*:}"
  if ! op_name_valid "$op_value"; then
    printf '\n\033[1;31m✗ invalid %s value: %s\033[0m\n' "$op_name" "$op_value" >&2
    printf '  Must match ^[A-Za-z0-9 ._-]+$ — real-world 1Password vault /\n' >&2
    printf '  item / field names are alphanumeric + space + . _ -.\n' >&2
    printf '  Shell metacharacters here would inject into the persistent\n' >&2
    printf '  $PROFILE / ~/.zshrc / ~/.bashrc line on every shell startup.\n' >&2
    exit 2
  fi
done
unset op_pair op_name op_value

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

# ── 1Password helpers ────────────────────────────────────────────────────────
# Mirror of the GCP path. Tokens live in a 1Password vault; profile lines
# read them via `op read` at shell start. The 1Password desktop app must be
# running with CLI integration enabled so `op` resolves without an extra
# session-token prompt on each shell invocation.

op_installed() { have op; }

op_authenticated() {
  op_installed && op whoami >/dev/null 2>&1
}

op_vault_item_resolves() {
  # $1=vault $2=item $3=field
  local val
  val=$(op read "op://$1/$2/$3" 2>/dev/null || true)
  [ -n "$val" ]
}

detect_existing_op_vault() {
  # All-or-nothing — both items must resolve to avoid false positives
  # that would strand the user with empty env vars.
  op_authenticated || return 1
  op_vault_item_resolves "$OP_VAULT" "$OP_ACCESS_ITEM" "$OP_FIELD" || return 1
  op_vault_item_resolves "$OP_VAULT" "$OP_PACKAGE_ITEM" "$OP_FIELD" || return 1
  return 0
}

install_op_cli() {
  # macOS: brew install --cask 1password-cli
  # Linux: die with manual install URL (no good auto-install path).
  if [ "$(uname)" = "Darwin" ]; then
    if have brew; then
      info "installing 1Password CLI via Homebrew..."
      brew install --cask 1password-cli || die "brew install 1password-cli failed"
      ok "1Password CLI installed"
    else
      die "Homebrew not found. Install Homebrew first (https://brew.sh), or install op manually: https://developer.1password.com/docs/cli/get-started/"
    fi
  else
    die "Automatic op install on Linux not supported. Install manually: https://developer.1password.com/docs/cli/get-started/, then re-run."
  fi
}

store_token_in_onepassword() {
  # Mirror store_token_in_gcp's shape exactly — single line written to
  # $PROFILE, single export in the current session. 2>/dev/null on the RHS
  # so a disconnected / locked 1Password app produces an empty env var
  # rather than a non-zero shell-startup exit. The `|| true` inside $()
  # defends against `set -e` in a sourced rc — interactive shells rarely
  # use errexit, but Forge-managed dev shells sometimes do, and a locked
  # 1Password app at shell-start should not kill the shell.
  local var_name=$1 item_name=$2
  local ref="op://${OP_VAULT}/${item_name}/${OP_FIELD}"
  local line="export ${var_name}=\"\$(op read \"${ref}\" 2>/dev/null || true)\""
  append_if_missing "$line" "$PROFILE"
  export "${var_name}"="$(op read "$ref" 2>/dev/null || true)"
}

clear_stale_keystore_entries() {
  # When onepassword backend is selected, sweep stale keystore entries to
  # enforce a single source of truth. Sweeps current names plus every
  # retired token name per docs/as-built/forge-access-token-provenance.md:
  #   FORGE_CODEX_TOKEN     — retired PR #230 (Forge Atlas rename)
  #   ATLAS_INGEST_TOKEN    — retired PR #552 (Forge-prefix consistency)
  #   CODEX_INGEST_TOKEN    — retired PR #544 (mechanical rename)
  #   FORGE_INGEST_TOKEN    — current ingest token; sweep so a stale value
  #                           can't shadow the 1Password-sourced one.
  # Idempotent — missing entries are not errors.
  local stale_names="FORGE_PACKAGE_TOKEN FORGE_ACCESS_TOKEN FORGE_CODEX_TOKEN ATLAS_INGEST_TOKEN CODEX_INGEST_TOKEN FORGE_INGEST_TOKEN"
  local name
  if have security; then
    for name in $stale_names; do
      if security find-generic-password -s "$name" -a "$USER" -w >/dev/null 2>&1; then
        security delete-generic-password -s "$name" -a "$USER" >/dev/null 2>&1 || true
        info "swept stale Keychain entry: $name"
      fi
    done
  elif have secret-tool; then
    for name in $stale_names; do
      if secret-tool lookup service "$name" >/dev/null 2>&1; then
        secret-tool clear service "$name" >/dev/null 2>&1 || true
        info "swept stale libsecret entry: $name"
      fi
    done
  fi
}

# ── Step 1: Node $NODE_VERSION via nvm ───────────────────────────────────────
#
# Fast path: if exactly Node $NODE_VERSION is already active on PATH, skip
# nvm entirely. Re-runs are non-destructive for healthy installs.
#
# Slow path: nvm install $NODE_VERSION — idempotent, won't re-download if
# already present. Pinning to the exact patch ensures every Forge client
# runs the same Node binary the sealed bundle was built against (Node ABI
# 127 for 22.x — tree-sitter prebuilds match).

step "Step 1 — Node ${NODE_VERSION}"

existing_node=""
if have node; then
  existing_node=$(node --version 2>/dev/null || true)
fi

if [ "$existing_node" = "v${NODE_VERSION}" ]; then
  ok "Node ${existing_node} already active (exact pin match) — skipping nvm"
else
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    info "nvm not found — installing to $NVM_DIR"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  fi

  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"

  if ! nvm ls "$NODE_VERSION" >/dev/null 2>&1; then
    info "installing Node ${NODE_VERSION} (this may take a minute)"
    nvm install "$NODE_VERSION" >/dev/null
  fi
  nvm use "$NODE_VERSION" >/dev/null
  nvm alias default "$NODE_VERSION" >/dev/null 2>&1 || true

  if ! have node; then
    die "node not on PATH after nvm use. Open a fresh shell and re-run the installer."
  fi
  current_node=$(node --version 2>/dev/null || true)
  if [ "$current_node" != "v${NODE_VERSION}" ]; then
    die "Node ${current_node} active but pin requires v${NODE_VERSION}. Run: nvm use ${NODE_VERSION}"
  fi
  ok "Node ${current_node} active (exact pin)"
fi

PROFILE=$(detect_shell_profile)
append_if_missing 'export NVM_DIR="$HOME/.nvm"' "$PROFILE"
append_if_missing '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' "$PROFILE"

# ── Step 2: choose secrets backend ───────────────────────────────────────────
#
# Self-heal on re-run: if the user already has FORGE_PACKAGE_TOKEN AND
# FORGE_ACCESS_TOKEN in the OS keystore (from a prior install), skip the
# backend prompt and auto-select `keystore`. This makes the installer
# zero-prompt for repeat runs — a pilot hitting the pre-0.6.0 bin-shim
# collision can re-run `./install.sh` and the installer heals state
# (sweeps shims, reinstalls scoped package, nukes stale command markdown,
# re-runs postinstall) without asking for anything.
#
# --force-tokens bypasses the detection for rotation / bad-token cases.

detect_existing_keystore_tokens() {
  # Returns 0 if both FORGE_PACKAGE_TOKEN + FORGE_ACCESS_TOKEN exist in
  # the platform's keystore. Non-zero otherwise.
  if have security; then
    security find-generic-password -s FORGE_PACKAGE_TOKEN -a "$USER" -w >/dev/null 2>&1 || return 1
    security find-generic-password -s FORGE_ACCESS_TOKEN  -a "$USER" -w >/dev/null 2>&1 || return 1
    return 0
  elif have secret-tool; then
    secret-tool lookup service FORGE_PACKAGE_TOKEN >/dev/null 2>&1 || return 1
    secret-tool lookup service FORGE_ACCESS_TOKEN  >/dev/null 2>&1 || return 1
    return 0
  fi
  return 1
}

if [ -z "$SECRETS_BACKEND" ] && [ "$FORCE_TOKENS" = "false" ]; then
  if detect_existing_keystore_tokens; then
    SECRETS_BACKEND="keystore"
    printf '\n  \033[1;36mDetected existing FORGE_PACKAGE_TOKEN + FORGE_ACCESS_TOKEN in OS\n'
    printf '  keystore — skipping backend prompt and token prompts. Running in\n'
    printf '  HEAL mode (reusing stored tokens, sweeping stale state, reinstalling).\n'
    printf '  Use --force-tokens to rotate.\033[0m\n'
  elif detect_existing_op_vault; then
    SECRETS_BACKEND="onepassword"
    printf '\n  \033[1;36mDetected existing FORGE_PACKAGE_TOKEN + FORGE_ACCESS_TOKEN in\n'
    printf '  1Password vault "%s" — skipping backend prompt and token\n' "$OP_VAULT"
    printf '  prompts. Running in HEAL mode (reusing stored tokens, sweeping stale\n'
    printf '  state, reinstalling). Use --force-tokens to rotate.\033[0m\n'
  fi
fi

# Prompt for backend if not supplied via --secrets=... and not auto-detected
if [ -z "$SECRETS_BACKEND" ]; then
  SECRETS_BACKEND=$(prompt_choice \
    "Where should the FORGE_PACKAGE_TOKEN and FORGE_ACCESS_TOKEN be stored?" \
    "keystore" \
    "keystore" \
    "gcp" \
    "onepassword")
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
elif [ "$SECRETS_BACKEND" = "onepassword" ]; then
  if ! op_installed; then
    if [ "$NON_INTERACTIVE" = "true" ]; then
      die "1Password CLI ('op') not found and --non-interactive set. Install op manually (https://developer.1password.com/docs/cli/get-started/) and re-run."
    fi
    answer=$(prompt_choice \
      "1Password CLI ('op') not found. Install it now?" \
      "yes" \
      "yes" \
      "no")
    if [ "$answer" = "yes" ]; then
      install_op_cli
    else
      die "1Password CLI ('op') is required for --secrets=onepassword. Install: https://developer.1password.com/docs/cli/get-started/"
    fi
  fi

  if ! op_authenticated; then
    die "1Password CLI not authenticated.

  Fix:
    1. Open the 1Password desktop app → Settings → Developer →
       enable \"Integrate with 1Password CLI\".
    2. (macOS only) On first integration the desktop app prompts for
       Touch ID / system password — that prompt can only be answered in
       a real terminal session, NOT through Claude Code or another agent
       shell. If you launched this installer through an agent, exit and
       re-run from Terminal.app / iTerm.
    3. Verify in your shell:  op whoami
    4. Re-run this installer."
  fi
  # Fixed acknowledgement — `op whoami` returns the account URL / email,
  # which is PII some compliance regimes treat as protected. The value is
  # not the token but is unnecessary signal on the operator's terminal.
  ok "1Password authentication verified"

  info "Vault:        ${OP_VAULT}"
  info "Package item: ${OP_PACKAGE_ITEM}"
  info "Access item:  ${OP_ACCESS_ITEM}"
  info "Field:        ${OP_FIELD}"

  # Probe both items up front — fail fast if either is unreachable.
  for item in "$OP_PACKAGE_ITEM" "$OP_ACCESS_ITEM"; do
    if ! op_vault_item_resolves "$OP_VAULT" "$item" "$OP_FIELD"; then
      die "1Password item 'op://${OP_VAULT}/${item}/${OP_FIELD}' did not resolve to a non-empty value. Check: vault name ('${OP_VAULT}'), item title ('${item}'), field name ('${OP_FIELD}'), and that your 1Password account has read access to this vault."
    fi
    ok "1Password item 'op://${OP_VAULT}/${item}/${OP_FIELD}' resolves"
  done

  # Enforce single source of truth — sweep any stale OS-keystore entries.
  clear_stale_keystore_entries
else
  if ! have security && ! have secret-tool; then
    die "no keystore found (tried: security, secret-tool). Install libsecret-tools or re-run with --secrets=gcp"
  fi
fi

# ── Step 3: FORGE_PACKAGE_TOKEN ──────────────────────────────────────────────

step "Step 3 — FORGE_PACKAGE_TOKEN → env var"

if [ "$SECRETS_BACKEND" = "gcp" ]; then
  store_token_in_gcp "FORGE_PACKAGE_TOKEN" "$GCP_PACKAGE_SECRET"
elif [ "$SECRETS_BACKEND" = "onepassword" ]; then
  store_token_in_onepassword "FORGE_PACKAGE_TOKEN" "$OP_PACKAGE_ITEM"
else
  store_token_in_keystore "FORGE_PACKAGE_TOKEN" "FORGE_PACKAGE_TOKEN (GitHub Packages read-access)"
fi

[ -n "${FORGE_PACKAGE_TOKEN:-}" ] || die "FORGE_PACKAGE_TOKEN empty after setup — check keystore/GCP/1Password configuration"
ok "FORGE_PACKAGE_TOKEN populated in current shell (length=${#FORGE_PACKAGE_TOKEN})"

# ── Step 4: ~/.npmrc ─────────────────────────────────────────────────────────

step "Step 4 — ~/.npmrc registry + auth"

NPMRC="$HOME/.npmrc"
append_if_missing "@bigbrainforge:registry=${REGISTRY_URL}" "$NPMRC"
append_if_missing "//${REGISTRY_HOST}/:_authToken=\${FORGE_PACKAGE_TOKEN}" "$NPMRC"
append_if_missing "always-auth=true" "$NPMRC"

# ── Step 5: npm install ──────────────────────────────────────────────────────

step "Step 5 — install ${PACKAGE_NAME}"

# Cleanup prior installs that collide on the `forge-plugin` bin name.
# See the install.ps1 counterpart for the full rationale — same two
# scenarios (deprecated public forge-plugin@* from pre-PR #230, or a
# partial install from an earlier crashed run) also hit Unix hosts.
# Both uninstall calls are idempotent.
info "Removing any stale forge-plugin shims from prior installs..."
npm uninstall -g forge-plugin --silent >/dev/null 2>&1 || true
npm uninstall -g "$PACKAGE_NAME" --silent >/dev/null 2>&1 || true

npm_prefix=$(npm config get prefix 2>/dev/null || echo "")
if [ -n "$npm_prefix" ]; then
  for shim in "$npm_prefix/bin/forge-plugin" "$npm_prefix/forge-plugin"; do
    if [ -e "$shim" ] || [ -L "$shim" ]; then
      if rm -f "$shim" 2>/dev/null; then
        info "removed stale shim: $shim"
      else
        warn "could not remove $shim — npm install may fail with EEXIST"
      fi
    fi
  done
fi

# Intentionally no version pin: `npm install -g @bigbrainforge/forge-plugin`
# resolves to the `@latest` dist-tag, which the release pipeline sets on
# every publish (release.yml publish-plugin step). The post-install verify
# below asserts we got @latest, fails loud if the registry returned an
# older version (corp mirror lag, npm cache poisoning, etc.).
npm install -g "$PACKAGE_NAME" --no-audit --no-fund
ok "ran npm install -g ${PACKAGE_NAME}"

# `npm list -g <pkg> --depth=0` prints lines like:
#   /usr/local/lib
#   └── @bigbrainforge/forge-plugin@2.2.0
# Split each line on `@`; for a scoped package the version is always the
# last @-delimited field (the leading `@` in the scope is the first delimiter
# producing an empty field, the second `@` precedes the version).
INSTALLED=$(npm list -g "$PACKAGE_NAME" --depth=0 2>/dev/null \
  | awk -F@ '/'"$(printf '%s' "$PACKAGE_NAME" | sed 's:[/&]:\\&:g')"'@/ {print $NF; exit}')
LATEST=$(npm view "$PACKAGE_NAME" version 2>/dev/null || echo "")
if [ -n "$INSTALLED" ] && [ -n "$LATEST" ]; then
  if [ "$INSTALLED" = "$LATEST" ]; then
    ok "installed ${PACKAGE_NAME}@${INSTALLED} (matches registry @latest)"
  else
    die "version mismatch: installed ${INSTALLED} but registry @latest is ${LATEST}. Possible causes: stale npm cache (npm cache clean --force), corporate registry mirror lag, or an incomplete release publish. Re-run after resolving."
  fi
elif [ -n "$INSTALLED" ]; then
  warn "installed ${PACKAGE_NAME}@${INSTALLED} but could not query registry @latest to verify (network / auth)"
else
  warn "${PACKAGE_NAME} installed but version could not be determined"
fi

# ── Step 6: FORGE_ACCESS_TOKEN ────────────────────────────────────────────────

step "Step 6 — FORGE_ACCESS_TOKEN → env var"

if [ "$SECRETS_BACKEND" = "gcp" ]; then
  store_token_in_gcp "FORGE_ACCESS_TOKEN" "$GCP_ACCESS_SECRET"
elif [ "$SECRETS_BACKEND" = "onepassword" ]; then
  store_token_in_onepassword "FORGE_ACCESS_TOKEN" "$OP_ACCESS_ITEM"
else
  store_token_in_keystore "FORGE_ACCESS_TOKEN" "FORGE_ACCESS_TOKEN (Forge MCP endpoint)"
fi

[ -n "${FORGE_ACCESS_TOKEN:-}" ] || warn "FORGE_ACCESS_TOKEN not populated in this shell (will be in new shells after profile reload)"

# ── Step 6.9: nuke stale plugin state before postinstall ─────────────────────
# Belt-and-suspenders for the pre-0.6.0 bin-shim collision trap.
#
# Scenario: a client on <= 0.5.29 runs install.sh to heal a broken install.
# Step 5 already swept both packages + shims and installed a fresh scoped
# @bigbrainforge/forge-plugin. But ~/.claude/commands/forge/ may still
# contain stale setup.md / help.md / etc. from the deprecated 0.5.x binary
# that wrote them. install.js's copyDir does overwrite matching files,
# but any file present in the OLD tree yet absent in the NEW one would
# linger — so we start from empty to guarantee a clean slate across major
# structure changes.
#
# We also clear ~/.claude/forge/VERSION + update-state.json so the
# postinstall writes them from scratch.
#
# ~/.claude/forge/bin/ is replaced by install.js's copy loop on every run
# — we let it handle that to avoid interfering with any running Node
# process holding a file handle. Backups under ~/.claude/forge/backup/
# are rollback material and left intact.

step "Step 6.9 — clear stale plugin state (idempotent re-run safety)"

for stale_path in \
  "$HOME/.claude/commands/forge" \
  "$HOME/.claude/forge/VERSION" \
  "$HOME/.claude/forge/update-state.json"
do
  if [ -e "$stale_path" ]; then
    if rm -rf "$stale_path" 2>/dev/null; then
      ok "cleared $stale_path"
    else
      warn "could not clear $stale_path (the postinstall will overwrite)"
    fi
  fi
done

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
  # Verify the canonical entry-point command landed. /forge:goal is the
  # entry point as of v2.2 (PR #574 deprecated and archived /forge:new);
  # this check is the durable invariant — every supported plugin version
  # ships goal.md.
  if [ ! -f "$HOME/.claude/commands/forge/goal.md" ]; then
    die "~/.claude/commands/forge/goal.md missing — plugin install did not complete"
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

  $(printf '\033[1;33m! Required next step — load FORGE_PACKAGE_TOKEN and FORGE_ACCESS_TOKEN:\033[0m')

    The installer appended env-var lines to: $PROFILE
    Existing shells (including the one running this installer) do NOT have
    those env vars set. Before launching Claude Code, either:

      $(printf '\033[1m• Open a new terminal\033[0m'), or
      $(printf '\033[1m• Run:  source %s\033[0m' "$PROFILE")

    Then verify both are populated:
      echo "pkg=\${#FORGE_PACKAGE_TOKEN} access=\${#FORGE_ACCESS_TOKEN}"
      # both lengths should be non-zero

  Next:
    1. Open a new shell (or source $PROFILE) — see above.
    2. Launch Claude Code from that shell so it inherits the env vars.
    3. In Claude Code, run:  /forge:help
    4. Start your first goal:    /forge:goal "<your-objective>"

  The plugin runs against your Forge MCP endpoint. No local CLI needed —
  atlas indexing is handled centrally by the Forge team.

  Troubleshooting: see client-install.md, or re-run this installer — it's
  idempotent.
EOF

# forge release: forge-v2.8.1
