# Forge CLI — Client Installation Guide

**Package:** `@bigbrainforge/forge`
**Version:** 0.5.23
**Supported platforms:** Windows x64, macOS arm64 (Apple Silicon)
**Runtime:** Node 22 LTS (installer sets this up for you)

---

## Table of Contents

1. [What you'll receive from BigBrain](#1-what-youll-receive-from-bigbrain)
2. [Quick install (recommended)](#2-quick-install-recommended)
3. [Secrets backends: OS keystore vs GCP Secret Manager](#3-secrets-backends-os-keystore-vs-gcp-secret-manager)
4. [First command + MCP push](#4-first-command--mcp-push)
5. [Manual install (fallback / reference)](#5-manual-install-fallback--reference)
6. [Troubleshooting](#6-troubleshooting)
7. [Updating](#7-updating)
8. [Quick reference](#8-quick-reference)

---

## 1. What you'll receive from BigBrain

Before you start, a BigBrain representative will send you — out-of-band via an enterprise password manager, never email/chat:

| Item | Purpose |
|---|---|
| **FORGE_PACKAGE_TOKEN** | Read access to the `@bigbrainforge` GitHub Packages registry (`read:packages` scope) |
| **`FORGE_ACCESS_TOKEN`** | Auth to your Forge MCP ingest endpoint |
| **Forge MCP endpoint URL** | e.g. `https://forge-mcp.bigbrainforge.com` |
| **Your repo/project identifier** | Pass to `forge codex index --repo-id <id>` |

If your organisation uses **GCP Secret Manager** (this is the default for our pilot clients), BigBrain will work with you to pre-populate two secrets in your GCP project:

- `FORGE_PACKAGE_TOKEN` — your GitHub Packages read-access token value
- `FORGE_ACCESS_TOKEN` — your MCP ingest token value

You'll pass the GCP project ID to the installer; nothing else about either secret touches your workstation.

---

## 2. Quick install (recommended)

The installer handles everything: Node 22 via nvm, registry config, secret storage, package install, shell profile wiring, and a smoke test. It **prompts** for the choices it needs — no flags required for normal use. Re-running is safe.

Both installers are published as assets on every `@bigbrainforge/forge` GitHub Release. The `/releases/latest/download/...` URL always resolves to the newest published version, so this doc doesn't need to change across releases.

### macOS (Apple Silicon) / Linux

```bash
curl -fsSL https://github.com/bigbrainforge/forge/releases/latest/download/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

The installer asks you which secrets backend to use (OS keystore or GCP Secret Manager), and — if you pick GCP — prompts for the project ID (defaulting to your current `gcloud config` project). Everything else is automatic.

### Windows (x64, PowerShell)

Run in a **non-elevated** PowerShell:

```powershell
Invoke-WebRequest https://github.com/bigbrainforge/forge/releases/latest/download/install.ps1 -OutFile install.ps1
.\install.ps1
```

If PowerShell blocks the script (execution policy), run once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

After the installer completes, **open a new terminal window** so the updated shell profile takes effect, then skip to [Section 4](#4-first-command--mcp-push).

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

The installer offers two backends for storing the FORGE_PACKAGE_TOKEN and `FORGE_ACCESS_TOKEN`. Both keep the secret out of any file on disk — the difference is *where* the encrypted value lives.

| | **OS keystore** (default) | **GCP Secret Manager** |
|---|---|---|
| Where stored | macOS Keychain / Windows Credential Manager | Your GCP project, encrypted at rest by Google |
| Access control | Per-user on the workstation | GCP IAM; rotatable centrally |
| Audit | OS-level only | Cloud Audit Logs |
| Prerequisites | None (built into macOS/Windows) | `gcloud` CLI installed + `gcloud auth login` completed; secrets pre-created |
| Rotation | Re-run installer | Update secret version in GCP; shell re-fetches on next startup |
| Offline resilience | Works offline | Shell startup needs network reachability to GCP (degrades to empty env var; `forge` will print a clear auth error) |

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
$env:FORGE_ACCESS_TOKEN     = (& gcloud secrets versions access latest --secret=FORGE_ACCESS_TOKEN --project=YOUR-PROJECT 2>$null)
```

The values populate `process.env` for every tool started from that shell — including `forge` and `npm install` — without ever being written anywhere else on your machine.

### Pre-creating the GCP secrets

A BigBrain engineer typically does this for you. If you're doing it yourself, with both token values in hand:

```bash
# FORGE_PACKAGE_TOKEN (GitHub Packages read-access)
printf 'ghp_xxxxxxxxxxxxxx' | \
  gcloud secrets create FORGE_PACKAGE_TOKEN --data-file=- --project=YOUR-PROJECT

# FORGE_ACCESS_TOKEN (MCP ingest)
printf 'your-mcp-token-here' | \
  gcloud secrets create FORGE_ACCESS_TOKEN --data-file=- --project=YOUR-PROJECT
```

Then grant read access to each engineer's GCP identity:

```bash
gcloud secrets add-iam-policy-binding FORGE_PACKAGE_TOKEN \
  --member='user:dev@example.com' --role='roles/secretmanager.secretAccessor' \
  --project=YOUR-PROJECT

gcloud secrets add-iam-policy-binding FORGE_ACCESS_TOKEN \
  --member='user:dev@example.com' --role='roles/secretmanager.secretAccessor' \
  --project=YOUR-PROJECT
```

Rotate a secret by creating a new version; shells automatically pick up the latest on next startup:

```bash
printf '<new-token>' | gcloud secrets versions add FORGE_ACCESS_TOKEN --data-file=- --project=YOUR-PROJECT
```

---

## 4. First command + MCP push

After the installer completes and you've opened a fresh shell:

```bash
# Verify the toolchain
forge --version                      # → 0.5.23
forge --help
forge codex --help

# Index a C# repo locally (no MCP push)
cd /path/to/your/repo
forge codex index --csharp-root . --output .forge/codex

# Index and push to your MCP endpoint
forge codex index --csharp-root . \
  --push https://forge-mcp.bigbrainforge.com \
  --repo-id your-assigned-repo-id
```

`forge` reads `FORGE_ACCESS_TOKEN` from the environment automatically. If it's missing, you get a clear error pointing you back to the installer or to [Section 6](#6-troubleshooting).

---

## 5. Manual install (fallback / reference)

Use this path only if the installer fails and you need to debug, or if your environment has restrictions that prevent the installer from running.

### 5.1 Install Node 22 LTS

**macOS:**
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

**Windows Credential Manager:** use the installer's embedded helper, or the CredentialManager PowerShell module:
```powershell
Install-Module CredentialManager -Scope CurrentUser
New-StoredCredential -Target 'FORGE_PACKAGE_TOKEN' -UserName 'forge' \
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

### 5.4 Install

```bash
npm install -g @bigbrainforge/forge
```

### 5.5 Store FORGE_ACCESS_TOKEN

Same pattern as step 5.2 but with `FORGE_ACCESS_TOKEN` as the env-var name and secret key. For the OS keystore path, the easiest way is:

```bash
forge shield fix shell-secret FORGE_ACCESS_TOKEN
```

Paste the emitted profile line into your shell profile. For GCP, append:

```bash
export FORGE_ACCESS_TOKEN="$(gcloud secrets versions access latest --secret=FORGE_ACCESS_TOKEN --project=YOUR-PROJECT 2>/dev/null)"
```

### 5.6 Verify

```bash
forge --version
```

---

## 6. Troubleshooting

### `npm install` fails with `401 Unauthorized`

Your FORGE_PACKAGE_TOKEN isn't reaching npm. Check:

```bash
# macOS
echo "length=${#FORGE_PACKAGE_TOKEN}"

# Windows
"length=$($env:FORGE_PACKAGE_TOKEN.Length)"
```

If zero-length, re-run the installer or re-source your profile (`source ~/.zshrc` / `. $PROFILE`). If still zero, verify the secret store contents:

```bash
# macOS keystore
security find-generic-password -s 'FORGE_PACKAGE_TOKEN' -a "$USER" -w

# GCP
gcloud secrets versions access latest --secret=FORGE_PACKAGE_TOKEN --project=YOUR-PROJECT
```

### `forge: requires Node 22 LTS`

Your current shell's Node isn't 22. Run `node --version`. Re-run the installer, or manually `nvm use 22`.

### `forge: command not found` after install

Global npm bin isn't on `PATH`. Find it:

```bash
npm config get prefix
# macOS/Linux: add "$(npm config get prefix)/bin" to PATH
# Windows: it's usually %APPDATA%\npm — add to PATH via System Properties
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

### MCP push fails with auth error

Verify `FORGE_ACCESS_TOKEN` is set:

```bash
# macOS
echo "length=${#FORGE_ACCESS_TOKEN}"
# Windows
"length=$($env:FORGE_ACCESS_TOKEN.Length)"
```

If zero, re-run installer or re-source profile.

### `tree-sitter-*` native binding fails to load

Rare; a grammar's prebuilt `.node` isn't matching your platform:

```bash
cd $(npm root -g)/@bigbrainforge/forge
npm rebuild tree-sitter tree-sitter-c-sharp tree-sitter-python
```

---

## 7. Updating

```bash
npm install -g @bigbrainforge/forge@latest
forge --version
```

Under GCP-secrets mode, rotating `FORGE_PACKAGE_TOKEN` or `FORGE_ACCESS_TOKEN` is a one-liner:

```bash
printf '<new-value>' | gcloud secrets versions add FORGE_PACKAGE_TOKEN --data-file=- --project=YOUR-PROJECT
# open a new shell — the rotated value is picked up automatically
```

---

## 8. Quick reference

| Task | Command |
|---|---|
| Run installer (macOS, keystore) | `./install.sh` |
| Run installer (macOS, GCP) | `./install.sh --secrets=gcp --gcp-project=P` |
| Run installer (Windows, keystore) | `.\install.ps1` |
| Run installer (Windows, GCP) | `.\install.ps1 -Secrets gcp -GcpProject P` |
| Update | `npm install -g @bigbrainforge/forge@latest` |
| Help | `forge --help`, `forge codex --help`, `forge shield --help` |
| Index repo | `forge codex index --csharp-root . --output .forge/codex` |
| Push to MCP | `forge codex index --csharp-root . --push <mcp-url> --repo-id <id>` |
| Audit machine | `forge shield audit` |

---

## Support

- **Install issues:** contact your BigBrain representative with the output of the installer and `forge --version`.
- **Runtime issues:** include the full command + output.
- **Security concerns:** email security@bigbrainforge.com — do not file as public GitHub issues.
