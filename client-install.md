# Forge Plugin — Client Installation Guide

**Package:** `@bigbrainforge/forge-plugin`
**Supported platforms:** Windows x64, macOS arm64 (Apple Silicon), Linux x64
**Runtime:** Node 22 LTS (installer sets this up for you)
**Requires:** Claude Code already installed ([claude.ai/code](https://claude.ai/code))

The Forge plugin is a Claude Code plugin — it adds slash commands (`/forge:goal`, `/forge:review`, `/forge:done`, `/forge:status`, etc.), a statusline hook, and registers the Forge MCP server in your Claude Code config. All orchestration runs server-side on the Forge MCP endpoint; the plugin itself is pure configuration and does not run atlas indexing locally.

---

## Table of Contents

1. [What you'll receive from BigBrain](#1-what-youll-receive-from-bigbrain)
2. [Quick install (recommended)](#2-quick-install-recommended)
3. [Secrets backends: OS keystore vs GCP Secret Manager vs 1Password](#3-secrets-backends-os-keystore-vs-gcp-secret-manager-vs-1password)
4. [After install — verify the plugin](#4-after-install--verify-the-plugin)
5. [Manual install (fallback / reference)](#5-manual-install-fallback--reference)
6. [Troubleshooting](#6-troubleshooting)
7. [Updating](#7-updating)
8. [Quick reference](#8-quick-reference)
9. [Onboarding teammates via a shared 1Password vault](#9-onboarding-teammates-via-a-shared-1password-vault)

---

## 1. What you'll receive from BigBrain

Before you start, a BigBrain representative will send you — out-of-band via an enterprise password manager, never email/chat:

| Item | Purpose |
|---|---|
| `FORGE_PACKAGE_TOKEN` | Read access to the `@bigbrainforge` GitHub Packages registry (`read:packages` scope). Used by `npm install` only. |
| `FORGE_ACCESS_TOKEN` | Bearer token for your Forge MCP endpoint. Used by the plugin's slash commands at runtime. |
| Forge MCP endpoint URL | e.g. `https://forge-mcp.bigbrainforge.com` (already wired into the plugin's default config) |
| Your repo/project identifier | Used when starting a Forge goal (`/forge:goal` will prompt) |

If your organisation uses **GCP Secret Manager** (the default for pilot clients), BigBrain will work with you to pre-populate two secrets in your GCP project:

- `FORGE_PACKAGE_TOKEN` — your GitHub Packages read-access token value
- `FORGE_ACCESS_TOKEN` — your MCP endpoint bearer token value

You'll pass the GCP project ID to the installer; nothing else about either secret touches your workstation.

If your organisation uses **1Password (Business or Teams)**, BigBrain will work with you to set up a shared vault (typical name: `Platform - AI - FORGE` or `<Client>-AI-FORGE`) containing two items, `FORGE_ACCESS_TOKEN` and `FORGE_PACKAGE_TOKEN` (each with the secret in the `credential` field). You're granted access to the vault with **View Only + View and Copy Passwords** permissions — no token values are ever transmitted out-of-band. Vault membership IS the secure delivery channel. 1Password Personal/Family plans do not support shared vaults; Teams or Business is required for this backend.

---

## 2. Quick install (recommended)

The installer handles everything: Node 22 via nvm, registry config, secret storage, plugin install, shell profile wiring, and verification. It **prompts** for the choices it needs — no flags required for normal use. Re-running is safe.

Both installer scripts are served from `bigbrainforge/forge-installers` (public repo, no auth required to download), so `curl` / `Invoke-WebRequest` work before you've configured any tokens.

### macOS — single-click install (recommended for 1Password orgs)

If your organisation uses the 1Password secrets backend, download **`install.command`** instead of `install.sh` and double-click it in Finder. The wrapper opens Terminal, fetches the latest `install.sh`, and runs it with `--secrets=onepassword --op-vault='Platform - AI - FORGE'` pre-set. The only prompt is the one-time Touch ID approval for 1Password CLI integration (macOS security; cannot be scripted).

```bash
curl -fsSL https://raw.githubusercontent.com/bigbrainforge/forge-installers/main/install.command -o ~/Downloads/install.command
chmod +x ~/Downloads/install.command
open ~/Downloads/install.command   # or double-click it in Finder
```

**Gatekeeper note (first run only):** until the file is signed with an Apple Developer ID + notarized, macOS will show "cannot be opened because it is from an unidentified developer" on the first double-click. Right-click → **Open** → confirm, and macOS remembers the approval. A notarized `.pkg` will replace this workaround in a later cut.

**Prerequisites the wrapper assumes:**
- Homebrew is already installed (`/opt/homebrew/bin/brew` exists). If not, install from [brew.sh](https://brew.sh) first.
- 1Password.app is installed in `/Applications/`. If not, install from [1password.com/downloads/mac/](https://1password.com/downloads/mac/) first.
- Your account has read access to the shared `Platform - AI - FORGE` vault (or whatever name your operator gave you — override with `FORGE_OP_VAULT='<your-vault>' open install.command`).

If any of those are missing, the wrapper bails early with a clear message before downloading Node or touching anything else.

### macOS (Apple Silicon) / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/bigbrainforge/forge-installers/main/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

The installer asks which secrets backend to use (OS keystore or GCP Secret Manager) and — if you pick GCP — prompts for the project ID (defaulting to your current `gcloud config` project). Everything else is automatic.

### Windows (x64, PowerShell)

Run in a **non-elevated** PowerShell:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/bigbrainforge/forge-installers/main/install.ps1 -OutFile install.ps1
.\install.ps1
```

If PowerShell blocks the script (execution policy), run once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

After the installer completes, you MUST either **open a new terminal** or **re-source your shell profile** (the installer prints the exact command). Existing shells don't have `FORGE_PACKAGE_TOKEN` or `FORGE_ACCESS_TOKEN` set — they only populate in shells started after the installer wrote to your profile. Then **restart Claude Code from that new shell** so the slash commands, statusline, and env vars all load together, and skip to [Section 4](#4-after-install--verify-the-plugin).

### Scripted / CI installs (skip the prompts)

Every prompt has a corresponding flag if you want a no-questions-asked run (useful in provisioning scripts):

```bash
# macOS/Linux, GCP
./install.sh --secrets=gcp --gcp-project=YOUR-PROJECT --non-interactive
```

```powershell
# Windows, GCP
.\install.ps1 -Secrets gcp -GcpProject YOUR-PROJECT -NonInteractive
```

```bash
# macOS/Linux, 1Password
./install.sh --secrets=onepassword --op-vault='Platform - AI - FORGE'
```

```powershell
# Windows, 1Password
.\install.ps1 -Secrets onepassword -OpVault 'Platform - AI - FORGE'
```

See `./install.sh --help` / `Get-Help .\install.ps1 -Full` for the full flag list.

---

## 3. Secrets backends: OS keystore vs GCP Secret Manager vs 1Password

The installer offers three backends for storing `FORGE_PACKAGE_TOKEN` and `FORGE_ACCESS_TOKEN`. All three keep the secret out of any file on disk — the difference is *where* the encrypted value lives.

| | **OS keystore** (default) | **GCP Secret Manager** | **1Password** |
|---|---|---|---|
| Where stored | macOS Keychain / Linux libsecret / Windows Credential Manager | Your GCP project, encrypted at rest by Google | Shared 1Password vault, encrypted at rest by 1Password |
| Access control | Per-user on the workstation | GCP IAM; rotatable centrally | 1Password vault ACL (View Only / View & Share / Manage / etc.) |
| Audit | OS-level only | Cloud Audit Logs | 1Password Business audit logs (per-user `op read` events) |
| Prerequisites | None (built into macOS/Windows; Linux needs `libsecret-tools`) | `gcloud` CLI installed + `gcloud auth login` completed; secrets pre-created | `op` CLI installed, signed in (desktop integration), vault access granted |
| Rotation | Re-run installer | Update secret version in GCP; shell re-fetches on next startup | Edit item value in 1Password; shell re-fetches on next startup |
| Offline resilience | Works offline | Shell startup needs network reachability to GCP (degrades to empty env var; plugin will print a clear auth error) | Works when 1Password desktop app is unlocked; cold-boot first-shell-after-unlock has slight delay |
| Best for | Single developer workstation, zero cloud dependencies | Centralized secret management with cloud-audited access | Multi-engineer client teams; centralized rotation without GCP overhead |

**Pick GCP Secret Manager if:** your org has centralized secret management, compliance requires cloud-audited secret access, or multiple engineers share secret rotation duties.

**Pick 1Password if:** your org already uses 1Password Business/Teams, you want to onboard engineers by adding them to a shared vault, and centralized rotation is needed without standing up GCP infrastructure.

**Pick OS keystore if:** you're a single developer workstation and want zero cloud dependencies.

### How the installer uses GCP Secret Manager

Rather than copying the secret values onto your workstation, the installer writes two lines to your shell profile that fetch from GCP at every shell startup:

```bash
# macOS/Linux, appended to ~/.zshrc or ~/.bashrc
export FORGE_PACKAGE_TOKEN="$(gcloud secrets versions access latest --secret=FORGE_PACKAGE_TOKEN --project=YOUR-PROJECT 2>/dev/null)"
export FORGE_ACCESS_TOKEN="$(gcloud secrets versions access latest --secret=FORGE_ACCESS_TOKEN --project=YOUR-PROJECT 2>/dev/null)"
```

```powershell
# Windows, appended to $PROFILE
$env:FORGE_PACKAGE_TOKEN = (& gcloud secrets versions access latest --secret=FORGE_PACKAGE_TOKEN --project=YOUR-PROJECT 2>$null)
$env:FORGE_ACCESS_TOKEN  = (& gcloud secrets versions access latest --secret=FORGE_ACCESS_TOKEN --project=YOUR-PROJECT 2>$null)
```

The values populate `process.env` for every process started from that shell — including `npm install` and the plugin's MCP client inside Claude Code — without ever being written anywhere else on your machine.

### Pre-creating the GCP secrets

A BigBrain engineer typically does this for you. If you're doing it yourself, with both token values in hand:

```bash
# FORGE_PACKAGE_TOKEN (GitHub Packages read-access)
printf 'ghp_xxxxxxxxxxxxxx' | \
  gcloud secrets create FORGE_PACKAGE_TOKEN --data-file=- --project=YOUR-PROJECT

# FORGE_ACCESS_TOKEN (MCP endpoint)
printf 'your-mcp-token-here' | \
  gcloud secrets create FORGE_ACCESS_TOKEN --data-file=- --project=YOUR-PROJECT
```

Then grant read access to each engineer's GCP identity:

```bash
for secret in FORGE_PACKAGE_TOKEN FORGE_ACCESS_TOKEN; do
  gcloud secrets add-iam-policy-binding "$secret" \
    --member='user:dev@example.com' --role='roles/secretmanager.secretAccessor' \
    --project=YOUR-PROJECT
done
```

Rotate a secret by creating a new version; shells automatically pick up the latest on next startup:

```bash
printf '<new-token>' | gcloud secrets versions add FORGE_ACCESS_TOKEN --data-file=- --project=YOUR-PROJECT
```

### How the installer uses 1Password

Rather than copying the secret values onto your workstation, the installer writes two lines to your shell profile that fetch from 1Password at every shell startup via the `op read` CLI:

```bash
# macOS/Linux, appended to ~/.zshrc or ~/.bashrc
export FORGE_PACKAGE_TOKEN="$(op read 'op://Platform - AI - FORGE/FORGE_PACKAGE_TOKEN/credential' 2>/dev/null)"
export FORGE_ACCESS_TOKEN="$(op read 'op://Platform - AI - FORGE/FORGE_ACCESS_TOKEN/credential' 2>/dev/null)"
```

```powershell
# Windows, appended to $PROFILE
$env:FORGE_PACKAGE_TOKEN = (& op read 'op://Platform - AI - FORGE/FORGE_PACKAGE_TOKEN/credential' 2>$null)
$env:FORGE_ACCESS_TOKEN  = (& op read 'op://Platform - AI - FORGE/FORGE_ACCESS_TOKEN/credential' 2>$null)
```

The vault name, item names, and field name are all configurable via `--op-vault` / `--op-access-item` / `--op-package-item` / `--op-field` (or the `-OpVault` / `-OpAccessItem` / `-OpPackageItem` / `-OpField` PowerShell equivalents). Defaults are `Platform - AI - FORGE`, `FORGE_ACCESS_TOKEN`, `FORGE_PACKAGE_TOKEN`, and `credential` respectively.

The installer auto-detects 1Password readiness when (a) `op` is on PATH, (b) `op whoami` succeeds, and (c) both vault items resolve to non-empty values. If you pass `--secrets=onepassword` but `op` is missing, the installer offers to install it via `winget install AgileBits.1Password.CLI` (Windows) or `brew install --cask 1password-cli` (macOS); on Linux it exits with the manual-install URL <https://developer.1password.com/docs/cli/get-started/>. When the 1Password backend activates, the installer also sweeps stale `FORGE_*` entries from the OS keystore (Credential Manager / Keychain / libsecret) so two backends never race.

Prereqs:

- 1Password **Business** or **Teams** account. Personal/Family plans only have Private vaults, which cannot be shared — they work for a single user but defeat the shared-vault onboarding model.
- 1Password CLI (`op`) installed and on PATH.
- 1Password desktop app installed with **Settings → Developer → Integrate with 1Password CLI** enabled. Without the desktop integration `op` falls back to a session-key prompt on every call, which breaks unattended shell startup.
- Vault access granted by the operator to your 1Password account.

### Pre-creating the 1Password items

A BigBrain operator typically does this for you. If you're doing it yourself, with both token values in hand:

```bash
# Create the shared vault (admin only)
op vault create 'Platform - AI - FORGE'

# Add the two items (FORGE_PACKAGE_TOKEN value piped from a secure source)
op item create --category=password --vault='Platform - AI - FORGE' \
  --title=FORGE_PACKAGE_TOKEN credential='ghp_xxxxxxxxxxxxxx'

op item create --category=password --vault='Platform - AI - FORGE' \
  --title=FORGE_ACCESS_TOKEN credential='your-mcp-token-here'
```

Then share the vault with each engineer using least-privilege permissions — **View Only + View and Copy Passwords**. In the 1Password admin UI, also disable **Copy and Share Items** and **Export Items** for non-admin members so the secret can be read into shell env vars but not exfiltrated via the UI.

Rotate a token by editing the item value in 1Password (web UI, desktop app, or `op item edit`); shells automatically pick up the latest on next startup:

```bash
op item edit FORGE_ACCESS_TOKEN credential='<new-token>' --vault='Platform - AI - FORGE'
```

---

## 4. After install — verify the plugin

The installer's final step runs `forge-plugin` (the bin from the installed package), which copies slash commands and the statusline hook into `~/.claude/` and registers the Forge MCP server with Claude Code.

After the installer exits:

1. **Load the tokens into your shell environment.** The installer appended profile lines that read `FORGE_PACKAGE_TOKEN` and `FORGE_ACCESS_TOKEN` from your secret store at shell startup — but the shell that ran the installer doesn't have them yet. Either:

   ```bash
   # macOS/Linux — open a new terminal, OR re-source the profile:
   source ~/.zshrc        # or: source ~/.bashrc / ~/.profile — whichever the installer updated
   ```

   ```powershell
   # Windows — open a new PowerShell window, OR dot-source $PROFILE:
   . $PROFILE
   ```

   Verify both tokens are populated (both lengths should be non-zero):

   ```bash
   # macOS/Linux
   echo "pkg=${#FORGE_PACKAGE_TOKEN} access=${#FORGE_ACCESS_TOKEN}"
   ```

   ```powershell
   # Windows
   "pkg=$($env:FORGE_PACKAGE_TOKEN.Length) access=$($env:FORGE_ACCESS_TOKEN.Length)"
   ```

2. **Restart Claude Code from that shell.** Close the existing Claude Code app/CLI completely and relaunch it from the shell where the env vars are set — Claude Code inherits its environment from the process that spawned it, so launching from a stale shell will leave the plugin unable to authenticate to the MCP server.

3. **Verify the plugin files landed:**

   ```bash
   # macOS/Linux
   ls ~/.claude/commands/forge/          # should list new.md, help.md, status.md, ...
   cat ~/.claude/forge/VERSION           # installed version
   ```

   ```powershell
   # Windows
   Get-ChildItem $HOME\.claude\commands\forge
   Get-Content   $HOME\.claude\forge\VERSION
   ```

4. **In Claude Code**, type `/forge:help` — you should see the command list.
5. **Start your first goal** with `/forge:goal "<your-objective>"`.

   The canonical Forge flow is **`/forge:goal → /forge:review → /forge:done`**:
   - `/forge:goal` — set a verifiable objective; Claude iterates until success criteria are met.
   - `/forge:review` — required code-review gate before shipping.
   - `/forge:done` — deliver: capture follow-ups to backlog, update roadmap, archive the session.

   Optional side-channel commands: `/forge:save` (mid-flight checkpoint), `/forge:resume` (pick up where you left off), `/forge:plan` (planning sketch). Use these as needed — they are not required steps in the canonical flow.

If slash commands fail with a clear auth error, the shell Claude Code inherited didn't have `FORGE_ACCESS_TOKEN` set. Re-run step 1 above, close and relaunch Claude Code from the refreshed shell.

---

## 5. Manual install (fallback / reference)

Use this path only if the installer fails and you need to debug, or if your environment has restrictions that prevent the installer from running.

### 5.1 Install Node 22 LTS

**macOS / Linux:**
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
# reload shell, then:
nvm install 22 && nvm use 22 && nvm alias default 22
```

**Windows:**
1. Install nvm-windows from https://github.com/coreybutler/nvm-windows/releases
2. Open new PowerShell: `nvm install 22; nvm use 22`

### 5.2 Store the FORGE_PACKAGE_TOKEN

Pick one:

**macOS Keychain:**
```bash
security add-generic-password -U -s 'FORGE_PACKAGE_TOKEN' -a "$USER" -w
# paste FORGE_PACKAGE_TOKEN at prompt (hidden)

# Add to ~/.zshrc:
export FORGE_PACKAGE_TOKEN="$(security find-generic-password -s 'FORGE_PACKAGE_TOKEN' -a "$USER" -w 2>/dev/null)"
```

**Linux libsecret:**
```bash
secret-tool store --label='FORGE_PACKAGE_TOKEN' service FORGE_PACKAGE_TOKEN
# Add to ~/.bashrc:
export FORGE_PACKAGE_TOKEN="$(secret-tool lookup service FORGE_PACKAGE_TOKEN 2>/dev/null)"
```

**Windows Credential Manager:** easiest via the installer's embedded Credman helper. If doing it entirely manually, use the CredentialManager PowerShell module (requires `Install-Module CredentialManager -Scope CurrentUser`):
```powershell
New-StoredCredential -Target 'FORGE_PACKAGE_TOKEN' -UserName 'forge' `
  -Password (Read-Host -AsSecureString) -Persist LocalMachine

# Add to $PROFILE:
$env:FORGE_PACKAGE_TOKEN = (Get-StoredCredential -Target 'FORGE_PACKAGE_TOKEN').GetNetworkCredential().Password
```

**GCP Secret Manager:** append this line to your shell profile:
```bash
export FORGE_PACKAGE_TOKEN="$(gcloud secrets versions access latest --secret=FORGE_PACKAGE_TOKEN --project=YOUR-PROJECT 2>/dev/null)"
```

**1Password CLI (`op`):** if your secret lives in a shared 1Password vault, install the `op` CLI (Windows: `winget install --id AgileBits.1Password.CLI -e`; macOS: `brew install --cask 1password-cli`; Linux: <https://developer.1password.com/docs/cli/get-started/>), then enable **Settings → Developer → Integrate with 1Password CLI** in the desktop app, sign in with `op signin`, and append one of:

```bash
# macOS / Linux — append to ~/.zshrc or ~/.bashrc
export FORGE_PACKAGE_TOKEN="$(op read 'op://Platform - AI - FORGE/FORGE_PACKAGE_TOKEN/credential' 2>/dev/null)"
```

```powershell
# Windows — append to $PROFILE
$env:FORGE_PACKAGE_TOKEN = (& op read 'op://Platform - AI - FORGE/FORGE_PACKAGE_TOKEN/credential' 2>$null)
```

Replace `Platform - AI - FORGE` with your vault name. The auto-installer's `--secrets=onepassword` / `-Secrets onepassword` flag writes these lines for you and also sweeps stale OS-keystore copies — manual setup is only needed if the installer fails.

### 5.3 Configure `~/.npmrc`

Append these three lines to `~/.npmrc` (path is `%USERPROFILE%\.npmrc` on Windows):

```
@bigbrainforge:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${FORGE_PACKAGE_TOKEN}
always-auth=true
```

### 5.4 Install the plugin package

```bash
npm install -g @bigbrainforge/forge-plugin
```

### 5.5 Store FORGE_ACCESS_TOKEN

Same pattern as §5.2 but with `FORGE_ACCESS_TOKEN` as the env-var name and secret key. Example (macOS Keychain):

```bash
security add-generic-password -U -s 'FORGE_ACCESS_TOKEN' -a "$USER" -w
# paste FORGE_ACCESS_TOKEN at prompt (hidden)

# Add to ~/.zshrc:
export FORGE_ACCESS_TOKEN="$(security find-generic-password -s 'FORGE_ACCESS_TOKEN' -a "$USER" -w 2>/dev/null)"
```

Or GCP:

```bash
export FORGE_ACCESS_TOKEN="$(gcloud secrets versions access latest --secret=FORGE_ACCESS_TOKEN --project=YOUR-PROJECT 2>/dev/null)"
```

Or 1Password (matches the §5.2 bold-paragraph block — same `op` CLI prereqs):

```bash
# macOS / Linux — append to ~/.zshrc or ~/.bashrc
export FORGE_ACCESS_TOKEN="$(op read 'op://Platform - AI - FORGE/FORGE_ACCESS_TOKEN/credential' 2>/dev/null || true)"
```

```powershell
# Windows — append to $PROFILE
$env:FORGE_ACCESS_TOKEN = (& op read 'op://Platform - AI - FORGE/FORGE_ACCESS_TOKEN/credential' 2>$null)
```

### 5.6 Run the plugin installer

```bash
forge-plugin
```

This copies slash commands and the statusline hook into `~/.claude/` and registers the Forge MCP server. Restart Claude Code afterward.

### 5.7 Verify

```bash
ls ~/.claude/commands/forge/
cat ~/.claude/forge/VERSION
```

---

## 6. Troubleshooting

### `npm install` fails with `401 Unauthorized`

Your `FORGE_PACKAGE_TOKEN` isn't reaching npm. Check:

```bash
# macOS/Linux
echo "length=${#FORGE_PACKAGE_TOKEN}"

# Windows
"length=$($env:FORGE_PACKAGE_TOKEN.Length)"
```

If zero-length, re-run the installer or re-source your profile (`source ~/.zshrc` / `. $PROFILE`). If still zero, verify the secret store contents:

```bash
# macOS Keychain
security find-generic-password -s 'FORGE_PACKAGE_TOKEN' -a "$USER" -w

# Linux libsecret
secret-tool lookup service FORGE_PACKAGE_TOKEN

# GCP
gcloud secrets versions access latest --secret=FORGE_PACKAGE_TOKEN --project=YOUR-PROJECT
```

### Slash commands don't appear in Claude Code

- Confirm `ls ~/.claude/commands/forge/` shows `.md` files.
- Confirm you've fully restarted Claude Code (close all windows/processes).
- Run `forge-plugin` again — it's idempotent and will re-copy any missing files.

### MCP server errors inside Claude Code

The plugin registers `forge-mcp` in Claude Code's MCP config with a bearer header that interpolates `${FORGE_ACCESS_TOKEN}` at Claude Code startup. If you see auth errors in slash-command output:

```bash
# macOS/Linux
echo "length=${#FORGE_ACCESS_TOKEN}"
# Windows
"length=$($env:FORGE_ACCESS_TOKEN.Length)"
```

If zero, re-source your profile and relaunch Claude Code from that shell. Claude Code inherits the env vars of the process that spawned it.

### Statusline not showing

Check `~/.claude/settings.json` — it should have a `statusLine` entry pointing at `~/.claude/hooks/forge-statusline.js`. If another tool owns the statusline and you want Forge's to replace it, re-run:

```bash
forge-plugin --force-statusline
```

### PowerShell execution policy blocks the installer

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### gcloud secret access errors during shell startup

If you see auth errors when opening a new shell under GCP mode, check:

```bash
gcloud auth list                    # is any account active?
gcloud config get-value project     # right project?
gcloud secrets describe FORGE_PACKAGE_TOKEN --project=YOUR-PROJECT
```

Common causes: expired `gcloud auth login` session (re-run it), wrong project, missing `roles/secretmanager.secretAccessor` IAM binding on your user.

### Version mismatch after `/forge:setup update` — upgrade from < 0.6.0

**Symptom.** After upgrading from a pre-0.6.0 install, `cat ~/.claude/forge/VERSION` shows an old version (e.g. `0.5.19`) even though `npm list -g @bigbrainforge/forge-plugin` shows the new one. `/forge:setup update` reports "already at latest" even when you're clearly not.

**Cause.** Bin-shim collision between the deprecated unscoped `forge-plugin` package (on npmjs.com, frozen since PR #230) and the current scoped `@bigbrainforge/forge-plugin` (on GH Packages). Both register a `forge-plugin` bin shim; whichever was installed last wins the PATH lookup. Pre-0.6.0 clients that had both packages installed would hit this on every update because the pre-0.6.0 `/forge:setup update` procedure didn't sweep the deprecated shim before `npm install`.

**Fix — re-run the installer.** From 0.6.2 onward the installer is fully self-healing. It auto-detects your existing tokens in the keystore, skips every prompt, does the aggressive sweep, reinstalls the scoped package, clears stale command markdown, and re-runs the postinstaller. One paste, zero prompts:

```powershell
# Windows (PowerShell 7+) — always fetch fresh installer, never a stale local copy
Remove-Item .\install.ps1 -Force -ErrorAction SilentlyContinue
Invoke-WebRequest -Uri https://raw.githubusercontent.com/bigbrainforge/forge-installers/main/install.ps1 -OutFile install.ps1 -UseBasicParsing
.\install.ps1
```

```bash
# macOS / Linux — always fetch fresh installer, never a stale local copy
rm -f install.sh
curl -fsSL https://raw.githubusercontent.com/bigbrainforge/forge-installers/main/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

The `Remove-Item` / `rm -f` first line is important: without it, a prior run's local `install.ps1` / `install.sh` can linger even though `Invoke-WebRequest` / `curl` should overwrite — observed in the field when cached / read-only file attributes prevent the overwrite silently. Always fetch fresh.

The installer will print a **HEAL mode** banner when it auto-detects existing tokens and runs silently from there.

**Verify.** After the installer finishes: `cat ~/.claude/forge/VERSION` must match `npm list -g @bigbrainforge/forge-plugin`. Restart Claude Code so the 0.6.0+ SessionStart + Stop hooks load — from there on, auto-update handles every subsequent release without manual intervention.

**To rotate tokens** (bad / expired): pass `-ForceTokens` (Windows) or `--force-tokens` (macOS/Linux) to force fresh prompts.

---

## 7. Updating

```bash
npm install -g @bigbrainforge/forge-plugin@latest
forge-plugin
```

Restart Claude Code afterward.

Under GCP-secrets mode, rotating either token is a one-liner:

```bash
printf '<new-value>' | gcloud secrets versions add FORGE_PACKAGE_TOKEN --data-file=- --project=YOUR-PROJECT
# open a new shell — the rotated value is picked up automatically
```

### 7.1 Rotating `FORGE_ACCESS_TOKEN`

**Authoritative procedure: [`docs/as-built/forge-access-token-provenance.md`](../../../docs/as-built/forge-access-token-provenance.md).** That document is the source of truth for the dual-token model (`FORGE_ACCESS_TOKEN` for read/tool calls, `FORGE_INGEST_TOKEN` for atlas push), the three-store invariant for `FORGE_ACCESS_TOKEN` (Cloudflare Worker + GitHub repo secret + every workstation keystore), and the rotation procedure that keeps them consistent. Read it before rotating.

The client-side mechanics for **your workstation copy** are below; the rest of the procedure (Cloudflare server + GitHub repo) lives in the provenance doc to keep one source of truth for the operator runbook.

#### Update your workstation keystore

Pick whichever applies to your OS:

```bash
# macOS
security add-generic-password -U -s FORGE_ACCESS_TOKEN -a "$USER" -w
```

```bash
# Linux
secret-tool store --label='Forge access token' service FORGE_ACCESS_TOKEN
```

```powershell
# Windows: Control Panel → Credential Manager → Windows Credentials →
# edit the FORGE_ACCESS_TOKEN generic credential. Or via the GUI's
# "Add a generic credential" if no entry exists yet.
```

#### Update your 1Password vault item

If you're on the 1Password backend, the workstation rotation step is a single edit in 1Password — no installer re-run needed. Open the `FORGE_ACCESS_TOKEN` item in the 1Password desktop app or web UI and paste the new value into the `credential` field. The next shell you open picks it up automatically via the `op read` profile line. From the CLI:

```bash
op item edit FORGE_ACCESS_TOKEN credential='<new-token>' --vault='Platform - AI - FORGE'
```

Then update the env var in your current shell so the new value takes effect immediately (new shells pick up from the keystore automatically):

```bash
# Bash / zsh
export FORGE_ACCESS_TOKEN=$(...)        # from your password manager / clipboard
```

```powershell
# pwsh — paste literally, do not echo
$env:FORGE_ACCESS_TOKEN = '<paste here>'
```

#### Sweep stale legacy entries

The 7.x installer sweeps `FORGE_CODEX_TOKEN` and `forge:FORGE_CODEX_TOKEN` automatically on every run. If you need to run it manually:

```bash
# Windows
cmdkey /delete:FORGE_CODEX_TOKEN
cmdkey /delete:forge:FORGE_CODEX_TOKEN

# macOS
security delete-generic-password -s FORGE_CODEX_TOKEN
security delete-generic-password -s forge:FORGE_CODEX_TOKEN

# Linux
secret-tool clear service FORGE_CODEX_TOKEN
secret-tool clear service forge:FORGE_CODEX_TOKEN
```

Missing-entry errors are expected and safe to ignore.

#### Verify

After updating the value:

```bash
node ~/.claude/forge/bin/stage.js token --verify
```

This is a real network probe (not a local lookup) — it POSTs to `/api/atlas/ingest` and reports auth status. Procedure details and response classification are in the provenance doc's "Verifying the post-rotation state" section.

---

## 8. Quick reference

| Task | Command |
|---|---|
| Run installer (macOS/Linux, keystore) | `./install.sh` |
| Run installer (macOS/Linux, GCP) | `./install.sh --secrets=gcp --gcp-project=P` |
| Run installer (macOS/Linux, 1Password) | `./install.sh --secrets=onepassword --op-vault='Platform - AI - FORGE'` |
| Run installer (Windows, keystore) | `.\install.ps1` |
| Run installer (Windows, GCP) | `.\install.ps1 -Secrets gcp -GcpProject P` |
| Run installer (Windows, 1Password) | `.\install.ps1 -Secrets onepassword -OpVault 'Platform - AI - FORGE'` |
| Re-run plugin file copy | `forge-plugin` |
| Update | `npm install -g @bigbrainforge/forge-plugin@latest && forge-plugin` |
| Recover from bin-shim collision (pre-0.6.0 upgrades) | `forge-plugin --cleanup` then reinstall |
| Uninstall | `forge-plugin --uninstall` |
| Verify install | `ls ~/.claude/commands/forge/` + `cat ~/.claude/forge/VERSION` |
| In Claude Code | `/forge:help`, `/forge:goal`, `/forge:review`, `/forge:done`, `/forge:status`, `/forge:save`, `/forge:resume` |

---

## 9. Onboarding teammates via a shared 1Password vault

The 1Password backend reduces engineer onboarding to "add to vault → run installer." No token values transit email, Slack, or any other channel — **vault membership is the only secret transmitted**.

### Operator side (one-time setup, then per-teammate add)

1. Create the shared vault in 1Password Business or Teams (suggested name: `Platform - AI - FORGE` or `<Client>-AI-FORGE`).
2. Add two items in the vault: `FORGE_ACCESS_TOKEN` and `FORGE_PACKAGE_TOKEN`, each with the token value in the `credential` field.
3. Grant each teammate access to the vault with **View Only + View and Copy Passwords** permissions. This is least-privilege for token consumers — they can read the value into `op read`, but cannot edit, share, or export it.
4. In the vault's permission settings, explicitly disable **Copy and Share Items** and **Export Items** for the non-admin member role.
5. Rotation stays admin-only: when a token rotates (per the [provenance doc](../../../docs/as-built/forge-access-token-provenance.md)), edit the item value in 1Password. Every teammate's next-opened shell picks up the new value automatically.

### Teammate side (per-workstation)

1. Install the 1Password desktop app and sign in to the account that was granted vault access.
2. **Settings → Developer → Integrate with 1Password CLI** — enable. (Without this, `op` prompts for a session key on every CLI call and breaks unattended shell startup.)
3. Install the 1Password CLI: `winget install --id AgileBits.1Password.CLI -e` (Windows), `brew install --cask 1password-cli` (macOS), or follow <https://developer.1password.com/docs/cli/get-started/> (Linux). The auto-installer can do this step for you if `op` is missing.
4. Run the installer with the 1Password backend:

   ```bash
   ./install.sh --secrets=onepassword
   ```

   ```powershell
   .\install.ps1 -Secrets onepassword
   ```

   That's the entire flow. The installer verifies `op whoami` succeeds, confirms both vault items resolve to non-empty values, writes the `op read` profile lines, sweeps any stale OS-keystore entries, and exits.
5. Open a new shell so the profile lines load, then [verify the plugin](#4-after-install--verify-the-plugin).

### Permissions note

**View Only + View and Copy Passwords** is the right answer for token consumers. **Manage Vault** / **Manage Items** belong only to the operators responsible for rotation. Mixing the two on the same role removes the least-privilege boundary that makes this backend defensible for compliance review.

---

## Support

- **Install issues:** contact your BigBrain representative with the installer output + `cat ~/.claude/forge/VERSION`.
- **Plugin / slash-command issues:** include the full command + output.
- **Security concerns:** email security@bigbrainforge.com — do not file as public GitHub issues.

<!-- forge release: forge-v2.6.1 -->
