# Forge Plugin — Client Installation Guide

**Package:** `@bigbrainforge/forge-plugin`
**Supported platforms:** Windows x64, macOS arm64 (Apple Silicon), Linux x64
**Runtime:** Node 24 LTS (installer sets this up for you)
**Requires:** Claude Code already installed ([claude.ai/code](https://claude.ai/code))

> **Native marketplace install.** The Forge plugin installs through Claude Code's built-in plugin marketplace — not via `npm install -g`. The `install.sh` / `install.ps1` scripts set up prerequisites (Node, tokens, `~/.npmrc`) **and** then install the plugin for you by running the `claude plugin` CLI (`claude plugin marketplace add bigbrainforge/forge-installers` followed by `claude plugin install forge@forge`). Nothing is copied into `~/.claude/` by the installer, and there is no `forge-plugin` bin. After the installer finishes you only load the two tokens and restart Claude Code. See [Quick install](#2-quick-install-recommended).

> **Runtime — Node 24 minimum.** Forge requires Node 24.15.0 (Krypton LTS) or newer. The installer checks your running Node and only installs Node 24.15.0 via nvm / nvm-windows when Node is missing or below that minimum; if your Node already satisfies the floor it is left untouched. The minimum can be revisited by Forge maintainers — contact your BigBrain representative if you need a different runtime.

The Forge plugin is a Claude Code plugin — it adds slash commands (`/forge:goal`, `/forge:review`, `/forge:done`, `/forge:status`, etc.), a statusline hook, and registers the Forge MCP server in your Claude Code config. All orchestration runs server-side on the Forge MCP endpoint; the plugin itself is pure configuration and does not run atlas indexing locally.

---

## Table of Contents

1. [What you'll receive from BigBrain](#1-what-youll-receive-from-bigbrain)
2. [Quick install (recommended)](#2-quick-install-recommended)
3. [Secrets backends: OS keystore vs GCP Secret Manager vs 1Password](#3-secrets-backends-os-keystore-vs-gcp-secret-manager-vs-1password)
4. [After install — load tokens, restart, verify](#4-after-install--load-tokens-restart-verify)
5. [Manual setup (fallback / reference)](#5-manual-setup-fallback--reference)
6. [Troubleshooting](#6-troubleshooting)
7. [Updating](#7-updating)
8. [Quick reference](#8-quick-reference)
9. [Onboarding teammates via a shared 1Password vault](#9-onboarding-teammates-via-a-shared-1password-vault)

---

## 1. What you'll receive from BigBrain

Before you start, a BigBrain representative will send you — out-of-band via an enterprise password manager, never email/chat:

| Item | Purpose |
|---|---|
| `FORGE_PACKAGE_TOKEN` | Read access to the `@bigbrainforge` GitHub Packages registry (`read:packages` scope). Claude Code uses it (via the `~/.npmrc` reference) to pull the plugin package when the installer runs `claude plugin install forge@forge`. |
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

Installation is one command, then a restart:

1. **Run the installer** (`install.sh` / `install.ps1`). It sets up prerequisites — Node 24 (only if yours is too old), registry config, secret storage, and shell-profile wiring — **and then installs the plugin for you** by running Claude Code's `claude plugin` CLI:

   ```text
   claude plugin marketplace add bigbrainforge/forge-installers
   claude plugin install forge@forge
   ```

   `claude plugin install` pulls `@bigbrainforge/forge-plugin` from the private registry using the `FORGE_PACKAGE_TOKEN` the installer put in the environment (plus the `~/.npmrc` reference it wrote). Claude Code's plugin system owns the install — nothing is copied into `~/.claude/`. The installer **prompts** for the choices it needs — no flags required for normal use. Re-running is safe.

2. **Load the two tokens and restart Claude Code.** After the installer exits, open a new shell (or re-source your profile) so `FORGE_PACKAGE_TOKEN` and `FORGE_ACCESS_TOKEN` are set, then (re)launch Claude Code from that shell. See [Section 4](#4-after-install--load-tokens-restart-verify).

If the `claude` CLI isn't on PATH when the installer runs (Claude Code not yet installed), the plugin-install step is skipped with a warning that prints the two `claude plugin` commands to run yourself afterward.

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

After the installer completes, you MUST either **open a new terminal** or **re-source your shell profile** (the installer prints the exact command). Existing shells don't have `FORGE_PACKAGE_TOKEN` or `FORGE_ACCESS_TOKEN` set — they only populate in shells started after the installer wrote to your profile. Then **launch Claude Code from that new shell** so it inherits the env vars. The installer already installed the plugin via the `claude plugin` CLI; go to [Section 4](#4-after-install--load-tokens-restart-verify) to load tokens, restart, and verify.

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

## 4. After install — load tokens, restart, verify

The installer already installed the plugin for you — it ran `claude plugin marketplace add bigbrainforge/forge-installers` and `claude plugin install forge@forge` as its last step. You do **not** type any `/plugin` commands. All that's left is to load the two tokens into your environment, restart Claude Code so it picks them up, and verify.

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

2. **Launch Claude Code from that shell.** Close the existing Claude Code app/CLI completely and relaunch it from the shell where the env vars are set — Claude Code inherits its environment from the process that spawned it, so launching from a stale shell will leave the plugin unable to authenticate to the MCP server. The restart also loads the plugin the installer installed (slash commands, statusline, and MCP registration).

3. **Verify the plugin is active.** In Claude Code, type `/forge:help` — you should see the command list. You can also confirm the plugin shows as installed with `claude plugin list` (or under the in-app `/plugin` view), which should list `forge@forge`.
4. **Start your first goal** with `/forge:goal "<your-objective>"`.

   The canonical Forge flow is **`/forge:goal → /forge:review → /forge:done`**:
   - `/forge:goal` — set a verifiable objective; Claude iterates until success criteria are met.
   - `/forge:review` — required code-review gate before shipping.
   - `/forge:done` — deliver: capture follow-ups to backlog, update roadmap, archive the session.

   Optional side-channel commands: `/forge:save` (mid-flight checkpoint), `/forge:resume` (pick up where you left off), `/forge:plan` (planning sketch). Use these as needed — they are not required steps in the canonical flow.

If slash commands fail with a clear auth error, the shell Claude Code inherited didn't have `FORGE_ACCESS_TOKEN` set. Re-run step 1 above, close and relaunch Claude Code from the refreshed shell.

---

## 4.5 Wire Atlas reindex CI (recommended)

Without auto-reindex CI, your Atlas Map drifts as code lands on `main`. The Forge MCP server's `/forge:goal` Atlas pre-fetch then surfaces stale-Atlas reindex prompts on every iteration, and graph results lag the actual repo state. Wiring this once gives your repo the same auto-reindex behaviour the `bigbrainforge/forge` repo has — every merge to `main` triggers a re-index push, so the next `/forge:goal` reasons on fresh graph truth.

### What `/forge:setup ci-reindex` does

The subcommand stamps a workflow file at `.github/workflows/atlas-reindex-on-merge.yml` into your repo. Once stamped, your repo **owns the file** — the operator commits it like any other source. Re-running the subcommand updates the same file in place; it is idempotent and never duplicates. The version banner at the top of the workflow records which Forge version stamped it, so a later `/forge:setup ci-reindex` shows a clean diff when the template evolves (new event source, hardened guard, etc.).

### Wire the repo secret first

CI needs its own copy of `FORGE_ACCESS_TOKEN`. Per [`.forge/practices/token-isolation.md`](../../../.forge/practices/token-isolation.md), your **workstation token must not be reused for CI** — mint a separate value for the GitHub repo secret so a CI-side leak cannot compromise the developer keystore. Coordinate with your BigBrain operator to mint the second token (same `openssl rand -base64 32` provenance) and add it as a server-side principal on the Forge MCP endpoint.

In your client repo on GitHub:

1. **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `FORGE_ACCESS_TOKEN`
   - Value: the CI-only bearer token (NOT the workstation value)
   - This is a **GitHub repo secret** (encrypted at rest, exposed only to workflows that reference `secrets.FORGE_ACCESS_TOKEN`).

2. **Settings → Secrets and variables → Actions → New repository secret** (second secret)
   - Name: `FORGE_PACKAGE_TOKEN`
   - Value: a **CI-only** GitHub PAT with **`read:packages` scope ONLY** (least-privilege — no `repo`, no `write:packages`)
   - This is what `npm install` in the workflow uses to pull `@bigbrainforge/forge` from the `@bigbrainforge` GitHub Packages registry so the `forge atlas index --push` step has a `forge` binary on the runner.
   - Per [`.forge/practices/token-isolation.md`](../../../.forge/practices/token-isolation.md), **mint a separate PAT for CI** — do NOT reuse your workstation `FORGE_PACKAGE_TOKEN`. Same rationale as the access token above: a CI-side leak must not compromise the developer keystore. Generate via GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens (or classic) with **only** the `read:packages` scope checked.

3. **Settings → Secrets and variables → Actions → Variables tab → New repository variable** (optional)
   - Name: `FORGE_MCP_URL`
   - Value: your MCP endpoint, e.g. `https://forge-mcp.bigbrainforge.com`
   - Leave it unset to accept the workflow default of `https://mcp.bigbrainforge.com`. This is a **variable**, not a secret — the URL is not sensitive, and putting it in the variables tab keeps it visible in the Actions UI for debugging.

### Step-by-step

```bash
# 1. Install the sealed CLI bundle so the workflow's `forge atlas index --push`
#    step has a `forge` binary in CI. The workstation installer already did this
#    for your dev machine; CI needs its own install step that the template bakes in.
npm install -g --ignore-scripts @bigbrainforge/forge@latest

# 2. From inside the client repo, stamp the workflow file via Claude Code:
claude
# then in Claude Code:
/forge:setup ci-reindex

# 3. Commit the stamped file to main so future PR merges fire it.
git add .github/workflows/atlas-reindex-on-merge.yml
git commit -m "ci: add Atlas reindex on merge"
git push
```

Then open a trivial PR, merge it, and watch the workflow run in the **Actions** tab.

### Verifying the workflow ran

```bash
gh run list --workflow=atlas-reindex-on-merge.yml --limit 3
```

The job's last step prints `Atlas re-index pushed to <url> successfully.` on success. Failed runs upload `atlas-stderr.log` as an artifact on the run page — download it from the run summary for debugging without touching production state.

### Updating the template later

When Forge ships a newer template (a new event source, hardened guard, env-var tweak, etc.), the operator re-runs `/forge:setup ci-reindex` from inside the client repo and commits the diff. The version banner at the top of the workflow shows which Forge version stamped it; comparing it against `cat ~/.claude/forge/VERSION` tells you whether a re-stamp is worth doing.

---

## 5. Manual setup (fallback / reference)

Use this path only if the installer fails and you need to debug, or if your environment has restrictions that prevent the installer from running. This is the by-hand equivalent of what the installer does: set up the prerequisites yourself (§5.1–§5.4), then install the plugin with the two `claude plugin` CLI commands in §5.5 — the same commands the installer runs.

### 5.1 Install Node 24 LTS (only if your Node is older)

Forge requires Node 24.15.0 or newer. If your existing Node already meets that floor, skip this step.

**macOS / Linux:**
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
# reload shell, then:
nvm install 24 && nvm use 24 && nvm alias default 24
```

**Windows:**
1. Install nvm-windows from https://github.com/coreybutler/nvm-windows/releases
2. Open new PowerShell: `nvm install 24; nvm use 24`

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

### 5.4 Store FORGE_ACCESS_TOKEN

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

### 5.5 Install the plugin via the marketplace

Open a new shell (so the profile lines above load both tokens), then run the two `claude plugin` CLI commands the installer would have run for you:

```bash
claude plugin marketplace add bigbrainforge/forge-installers
claude plugin install forge@forge
```

`claude plugin install` pulls `@bigbrainforge/forge-plugin` from the private registry using the `FORGE_PACKAGE_TOKEN` your `~/.npmrc` reference resolves, then installs the slash commands, statusline hook, and MCP registration natively. (The in-app `/plugin marketplace add` / `/plugin install forge@forge` slash commands are the GUI equivalent if you prefer to run them from inside Claude Code.) Launch Claude Code from the same shell so it loads the plugin and inherits the env vars.

### 5.6 Verify

In Claude Code, run `/forge:help` — you should see the command list. You can also confirm the plugin shows as installed with `claude plugin list` (or under the in-app `/plugin` view).

---

## 6. Troubleshooting

### `claude plugin install` fails with `401 Unauthorized`

Your `FORGE_PACKAGE_TOKEN` isn't reaching the registry when the plugin package is pulled (during the installer's plugin-install step, or when you run `claude plugin install forge@forge` yourself). Check:

```bash
# macOS/Linux
echo "length=${#FORGE_PACKAGE_TOKEN}"

# Windows
"length=$($env:FORGE_PACKAGE_TOKEN.Length)"
```

If zero-length, re-run the installer (it'll re-attempt the plugin install) or re-source your profile (`source ~/.zshrc` / `. $PROFILE`) and re-run `claude plugin install forge@forge` yourself. If still zero, verify the secret store contents:

```bash
# macOS Keychain
security find-generic-password -s 'FORGE_PACKAGE_TOKEN' -a "$USER" -w

# Linux libsecret
secret-tool lookup service FORGE_PACKAGE_TOKEN

# GCP
gcloud secrets versions access latest --secret=FORGE_PACKAGE_TOKEN --project=YOUR-PROJECT
```

### Slash commands don't appear in Claude Code

- Confirm the plugin shows as installed via `claude plugin list` or under the in-app `/plugin` view (it should list `forge@forge`). If it doesn't, run `claude plugin install forge@forge` (or re-run the installer).
- Confirm you've fully restarted Claude Code (close all windows/processes) after the install — the plugin's commands and hooks load at startup.
- If the install failed, check the `401 Unauthorized` item above (FORGE_PACKAGE_TOKEN not reaching the registry).

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

The plugin's statusline is managed by Claude Code's plugin system. Confirm the plugin is installed and active under `/plugin`, then fully restart Claude Code. If another tool owns the statusline, disabling that tool's statusline (or its plugin) lets Forge's take over on the next restart.

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

### Rotating bad / expired tokens

To replace stored tokens (e.g. a `401` from a rotated `FORGE_PACKAGE_TOKEN`), re-run the installer with the force flag so it re-prompts instead of silently reusing the stale value: `-ForceTokens` (Windows) or `--force-tokens` (macOS/Linux). Then relaunch Claude Code from a fresh shell.

---

## 7. Updating

Plugin updates are handled by Claude Code's native marketplace — there is no `npm install -g` step. To pick up a newer plugin release, run `claude plugin update forge` (or, from inside Claude Code, refresh the `bigbrainforge/forge-installers` marketplace and update `forge@forge` via `/plugin`), and restart Claude Code when prompted. Token rotation is unchanged from the prerequisite setup, covered below.

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
| Rotate stored tokens | `./install.sh --force-tokens` / `.\install.ps1 -ForceTokens` |
| Add the Forge marketplace (the installer runs this) | `claude plugin marketplace add bigbrainforge/forge-installers` |
| Install the plugin (the installer runs this) | `claude plugin install forge@forge` |
| Update the plugin | `claude plugin update forge` |
| Uninstall the plugin | `claude plugin uninstall forge` |
| List installed plugins | `claude plugin list` |
| Verify install (in Claude Code) | `/forge:help` (or `claude plugin list`) |
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

   That's the entire prerequisite flow. The installer verifies `op whoami` succeeds, confirms both vault items resolve to non-empty values, writes the `op read` profile lines, sweeps any stale OS-keystore entries, and exits.
5. Open a new shell so the profile lines load, then launch Claude Code. The installer already installed the plugin via the `claude plugin` CLI — see [Section 4](#4-after-install--load-tokens-restart-verify) to verify.

### Permissions note

**View Only + View and Copy Passwords** is the right answer for token consumers. **Manage Vault** / **Manage Items** belong only to the operators responsible for rotation. Mixing the two on the same role removes the least-privilege boundary that makes this backend defensible for compliance review.

---

## Support

- **Install issues:** contact your BigBrain representative with the installer output + `cat ~/.claude/forge/VERSION`.
- **Plugin / slash-command issues:** include the full command + output.
- **Security concerns:** email security@bigbrainforge.com — do not file as public GitHub issues.

<!-- forge release: forge-v3.0.2 -->
