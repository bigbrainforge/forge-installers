# Forge Plugin — Client Installation Guide

**Package:** `@bigbrainforge/forge-plugin`
**Supported platforms:** Windows x64, macOS arm64 (Apple Silicon), Linux x64
**Runtime:** Node 22 LTS (installer sets this up for you)
**Requires:** Claude Code already installed ([claude.ai/code](https://claude.ai/code))

The Forge plugin is a Claude Code plugin — it adds slash commands (`/forge:new`, `/forge:status`, etc.), a statusline hook, and registers the Forge MCP server in your Claude Code config. All orchestration runs server-side on the Forge MCP endpoint; the plugin itself is pure configuration and does not run codex indexing locally.

---

## Table of Contents

1. [What you'll receive from BigBrain](#1-what-youll-receive-from-bigbrain)
2. [Quick install (recommended)](#2-quick-install-recommended)
3. [Secrets backends: OS keystore vs GCP Secret Manager](#3-secrets-backends-os-keystore-vs-gcp-secret-manager)
4. [After install — verify the plugin](#4-after-install--verify-the-plugin)
5. [Manual install (fallback / reference)](#5-manual-install-fallback--reference)
6. [Troubleshooting](#6-troubleshooting)
7. [Updating](#7-updating)
8. [Quick reference](#8-quick-reference)

---

## 1. What you'll receive from BigBrain

Before you start, a BigBrain representative will send you — out-of-band via an enterprise password manager, never email/chat:

| Item | Purpose |
|---|---|
| `FORGE_PACKAGE_TOKEN` | Read access to the `@bigbrainforge` GitHub Packages registry (`read:packages` scope). Used by `npm install` only. |
| `FORGE_ACCESS_TOKEN` | Bearer token for your Forge MCP endpoint. Used by the plugin's slash commands at runtime. |
| Forge MCP endpoint URL | e.g. `https://forge-mcp.bigbrainforge.com` (already wired into the plugin's default config) |
| Your repo/project identifier | Used when starting a Forge session (`/forge:new` will prompt) |

If your organisation uses **GCP Secret Manager** (the default for pilot clients), BigBrain will work with you to pre-populate two secrets in your GCP project:

- `FORGE_PACKAGE_TOKEN` — your GitHub Packages read-access token value
- `FORGE_ACCESS_TOKEN` — your MCP endpoint bearer token value

You'll pass the GCP project ID to the installer; nothing else about either secret touches your workstation.

---

## 2. Quick install (recommended)

The installer handles everything: Node 22 via nvm, registry config, secret storage, plugin install, shell profile wiring, and verification. It **prompts** for the choices it needs — no flags required for normal use. Re-running is safe.

Both installer scripts are served from `bigbrainforge/forge-installers` (public repo, no auth required to download), so `curl` / `Invoke-WebRequest` work before you've configured any tokens.

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
# macOS/Linux
./install.sh --secrets=gcp --gcp-project=YOUR-PROJECT --non-interactive
```

```powershell
# Windows
.\install.ps1 -Secrets gcp -GcpProject YOUR-PROJECT -NonInteractive
```

See `./install.sh --help` / `Get-Help .\install.ps1 -Full` for the full flag list.

---

## 3. Secrets backends: OS keystore vs GCP Secret Manager

The installer offers two backends for storing `FORGE_PACKAGE_TOKEN` and `FORGE_ACCESS_TOKEN`. Both keep the secret out of any file on disk — the difference is *where* the encrypted value lives.

| | **OS keystore** (default) | **GCP Secret Manager** |
|---|---|---|
| Where stored | macOS Keychain / Linux libsecret / Windows Credential Manager | Your GCP project, encrypted at rest by Google |
| Access control | Per-user on the workstation | GCP IAM; rotatable centrally |
| Audit | OS-level only | Cloud Audit Logs |
| Prerequisites | None (built into macOS/Windows; Linux needs `libsecret-tools`) | `gcloud` CLI installed + `gcloud auth login` completed; secrets pre-created |
| Rotation | Re-run installer | Update secret version in GCP; shell re-fetches on next startup |
| Offline resilience | Works offline | Shell startup needs network reachability to GCP (degrades to empty env var; plugin will print a clear auth error) |

**Pick GCP Secret Manager if:** your org has centralized secret management, compliance requires cloud-audited secret access, or multiple engineers share secret rotation duties.

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
5. **Start your first session** with `/forge:new`.

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

**Symptom.** After upgrading from a pre-0.6.0 install, `cat ~/.claude/forge/VERSION` shows an old version (e.g. `0.5.19`) even though `npm list -g @bigbrainforge/forge-plugin` shows the new one (e.g. `0.6.0`). Running `forge-plugin` also reports the old version.

**Cause.** Bin-shim collision between the deprecated unscoped `forge-plugin` package (on npmjs.com, frozen since PR #230) and the current scoped `@bigbrainforge/forge-plugin` (on GH Packages). Both register a `forge-plugin` bin shim; whichever was installed last wins the PATH lookup. Pre-0.6.0 clients that had both packages installed would hit this on every update because the pre-0.6.0 `/forge:setup update` procedure didn't sweep the deprecated shim before `npm install`. From 0.6.0 onward the update flow sweeps automatically, so this is a one-time bootstrap issue.

**Fix.** Run the cleanup subcommand, then reinstall:

```bash
# macOS / Linux
forge-plugin --cleanup
npm install -g --ignore-scripts @bigbrainforge/forge-plugin@latest
forge-plugin
```

```powershell
# Windows (PowerShell 7+)
forge-plugin --cleanup
npm install -g --ignore-scripts @bigbrainforge/forge-plugin@latest
forge-plugin
```

**If `forge-plugin --cleanup` itself doesn't exist yet** (the shim on PATH is the deprecated 0.5.x binary that predates the flag), do the sweep manually:

```powershell
# Windows — manual sweep
npm uninstall -g forge-plugin
npm uninstall -g @bigbrainforge/forge-plugin
$npmPrefix = (npm config get prefix).Trim()
@('forge-plugin', 'forge-plugin.cmd', 'forge-plugin.ps1') | ForEach-Object {
    Remove-Item -Path (Join-Path $npmPrefix $_) -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $npmPrefix 'bin' $_) -Force -ErrorAction SilentlyContinue
}
Get-Command forge-plugin -ErrorAction SilentlyContinue   # should print nothing
npm install -g --ignore-scripts @bigbrainforge/forge-plugin@latest
forge-plugin
```

```bash
# macOS / Linux — manual sweep
npm uninstall -g forge-plugin
npm uninstall -g @bigbrainforge/forge-plugin
NPM_PREFIX=$(npm config get prefix)
for leaf in forge-plugin forge-plugin.cmd forge-plugin.ps1; do
  rm -f "$NPM_PREFIX/$leaf" "$NPM_PREFIX/bin/$leaf"
done
which forge-plugin || true   # should print nothing
npm install -g --ignore-scripts @bigbrainforge/forge-plugin@latest
forge-plugin
```

**Verify.** After reinstall, `cat ~/.claude/forge/VERSION` must match `npm list -g @bigbrainforge/forge-plugin`. Restart Claude Code so the 0.6.0 SessionStart + Stop hooks load — from there on, auto-update handles every subsequent release.

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

---

## 8. Quick reference

| Task | Command |
|---|---|
| Run installer (macOS/Linux, keystore) | `./install.sh` |
| Run installer (macOS/Linux, GCP) | `./install.sh --secrets=gcp --gcp-project=P` |
| Run installer (Windows, keystore) | `.\install.ps1` |
| Run installer (Windows, GCP) | `.\install.ps1 -Secrets gcp -GcpProject P` |
| Re-run plugin file copy | `forge-plugin` |
| Update | `npm install -g @bigbrainforge/forge-plugin@latest && forge-plugin` |
| Recover from bin-shim collision (pre-0.6.0 upgrades) | `forge-plugin --cleanup` then reinstall |
| Uninstall | `forge-plugin --uninstall` |
| Verify install | `ls ~/.claude/commands/forge/` + `cat ~/.claude/forge/VERSION` |
| In Claude Code | `/forge:help`, `/forge:new`, `/forge:status`, `/forge:continue`, `/forge:complete` |

---

## Support

- **Install issues:** contact your BigBrain representative with the installer output + `cat ~/.claude/forge/VERSION`.
- **Plugin / slash-command issues:** include the full command + output.
- **Security concerns:** email security@bigbrainforge.com — do not file as public GitHub issues.
