<#
.SYNOPSIS
    @bigbrainforge/forge-plugin — Windows prerequisite installer.

.DESCRIPTION
    Sets up everything the Forge Claude Code plugin needs, then installs the
    plugin through Claude Code's marketplace. Handles:
      - Node: install via nvm-windows only if the client's Node is missing or
        below the repo minimum (otherwise their existing Node is left untouched)
      - FORGE_PACKAGE_TOKEN storage (Windows Credential Manager, GCP Secret Manager, or 1Password)
      - .npmrc registry + auth reference (the token stays in the env, never on disk)
      - FORGE_ACCESS_TOKEN storage (same secrets backend)
      - PowerShell $PROFILE wiring
      - claude plugin marketplace add + claude plugin install forge@forge

    The plugin installs natively via Claude Code's CLI — this script runs
    `claude plugin marketplace add bigbrainforge/forge-installers` then
    `claude plugin install forge@forge`. Claude Code pulls the package from the
    private registry using the FORGE_PACKAGE_TOKEN this script put in your
    environment. Nothing is copied into ~/.claude/ by this script, and no
    `forge` CLI is installed locally. Claude Code must already be installed.

    Re-run is safe — all operations are idempotent.

.PARAMETER Secrets
    Where to store secrets. "keystore" = Windows Credential Manager (default).
    "gcp" = GCP Secret Manager via gcloud.
    "onepassword" = 1Password CLI (op) reading from a shared vault at shell start.

.PARAMETER GcpProject
    GCP project ID for Secret Manager (required when Secrets=gcp).

.PARAMETER GcpPackageSecret
    Secret name holding the FORGE_PACKAGE_TOKEN. Default: FORGE_PACKAGE_TOKEN.

.PARAMETER GcpAccessSecret
    Secret name holding FORGE_ACCESS_TOKEN. Default: FORGE_ACCESS_TOKEN.

.PARAMETER OpVault
    1Password vault name (when Secrets=onepassword). Default: 'Platform - AI - FORGE'.
    Must be a vault your 1Password account has access to. Private vaults are
    not shareable in 1Password — use a Teams/Business shared vault for teams.

.PARAMETER OpAccessItem
    1Password item title holding the FORGE_ACCESS_TOKEN value. Default:
    FORGE_ACCESS_TOKEN.

.PARAMETER OpPackageItem
    1Password item title holding the FORGE_PACKAGE_TOKEN value. Default:
    FORGE_PACKAGE_TOKEN.

.PARAMETER OpField
    1Password field name within each item that holds the secret. Default:
    credential.

.EXAMPLE
    .\install.ps1
    # interactive, Windows Credential Manager

.EXAMPLE
    .\install.ps1 -Secrets gcp -GcpProject my-proj
    # uses GCP Secret Manager with default secret names

.EXAMPLE
    .\install.ps1 -Secrets onepassword -OpVault 'Platform - AI - FORGE'
    # uses 1Password CLI (op) to read FORGE_ACCESS_TOKEN + FORGE_PACKAGE_TOKEN
    # from a shared vault at every shell startup. No tokens written to
    # Windows Credential Manager. Auto-installs op via winget if missing.

.NOTES
    Pre-populate secrets in GCP before running with -Secrets gcp:
      "ghp_..."  | gcloud secrets create FORGE_PACKAGE_TOKEN  --data-file=- --project=PROJECT
      "mcp..."   | gcloud secrets create FORGE_ACCESS_TOKEN --data-file=- --project=PROJECT

    Pre-populate items in 1Password before running with -Secrets onepassword:
      In the shared vault, create two items titled FORGE_ACCESS_TOKEN and
      FORGE_PACKAGE_TOKEN, each with the secret value in the 'credential'
      field. Grant teammates View Only + View and Copy Passwords (least
      privilege for token consumers). The 1Password desktop app must be
      installed and signed in, and CLI integration enabled at:
        Settings -> Developer -> "Integrate with 1Password CLI"
#>

[CmdletBinding()]
param(
    # If not supplied, the installer prompts for this interactively.
    [ValidateSet('', 'keystore', 'gcp', 'onepassword')]
    [string]$Secrets = '',

    # If not supplied under -Secrets gcp, the installer prompts for this.
    [string]$GcpProject = '',

    [string]$GcpPackageSecret = 'FORGE_PACKAGE_TOKEN',

    [string]$GcpAccessSecret = 'FORGE_ACCESS_TOKEN',

    # 1Password backend defaults — used when -Secrets onepassword. Vault is
    # the shared vault containing both token items; default matches the
    # BigBrain operator pattern. Item titles default to the env-var names
    # so a fresh setup needs zero customization. Field defaults to
    # 'credential' which is what 1Password's API Credential template uses.
    #
    # ValidatePattern at parse time prevents shell-metachar injection into
    # the persistent $PROFILE line written by Install-TokenInOnePassword.
    # Real-world 1Password vault / item / field names are alphanumeric +
    # space + . _ -. Anything else (quote, dollar, backtick, semicolon,
    # pipe, ampersand, parenthesis, newline) gets rejected loudly BEFORE
    # Add-ProfileLine writes a line that re-executes on every shell start.
    # The default 'Platform - AI - FORGE' is safe by construction.
    [ValidatePattern('^[A-Za-z0-9 _.\-]+$')]
    [string]$OpVault = 'Platform - AI - FORGE',

    [ValidatePattern('^[A-Za-z0-9 _.\-]+$')]
    [string]$OpAccessItem = 'FORGE_ACCESS_TOKEN',

    [ValidatePattern('^[A-Za-z0-9 _.\-]+$')]
    [string]$OpPackageItem = 'FORGE_PACKAGE_TOKEN',

    [ValidatePattern('^[A-Za-z0-9 _.\-]+$')]
    [string]$OpField = 'credential',

    [switch]$NonInteractive,

    # Force fresh token prompts even if existing tokens are detected in
    # Credential Manager or GCP. Use for rotation, or when the stored
    # tokens are known bad (e.g. 401 from GitHub Packages). Without this
    # flag the installer auto-detects and reuses existing tokens silently,
    # making re-runs a zero-prompt self-heal.
    [switch]$ForceTokens
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.4.0'
# Minimum Node the plugin + Forge tooling require, AND the version installed via
# nvm-windows when the client's Node is missing or too old. Mirrors the repo's
# .nvmrc floor; a test in the forge-dist suite fails if the two ever drift
# apart. We do not force an exact version on clients — any Node >= this is left
# in place. (Declared as $NODE_VERSION; PowerShell variable names are
# case-insensitive, so the $NODE_VERSION usages below reference this same value.)
$NODE_VERSION = '24.15.0'
$PackageName = '@bigbrainforge/forge-plugin'
$RegistryUrl = 'https://npm.pkg.github.com'
$RegistryHost = 'npm.pkg.github.com'
$PatVar = 'FORGE_PACKAGE_TOKEN'
$TokVar = 'FORGE_ACCESS_TOKEN'

# ── Auto-detect non-interactive context (no controlling TTY) ─────────────────
#
# When the installer runs through an agent shell (Claude Code's pwsh tool, CI
# without an allocated console, redirected stdin), Read-Host reads from the
# redirected stream rather than a real console. Without a real console the
# prompt helpers would either block on empty input or echo unanswerable
# questions into the agent's transcript. Detect that case once at startup and
# auto-engage -NonInteractive so the prompts use defaults silently. Users
# running through an agent must supply all needed values via flags; the
# helpers below already enforce "required value missing" with a clear Die
# (e.g. -GcpProject under -Secrets gcp).
#
# Windows analogue of the install.sh `: > /dev/tty` write-test: check whether
# stdin OR stdout is redirected. Either redirection rules out a real TTY.
if (-not $NonInteractive) {
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
            $NonInteractive = $true
        }
    } catch {
        # [Console] members not available (rare hosts) — assume non-interactive
        # rather than crashing the installer on startup.
        $NonInteractive = $true
    }
    if ($NonInteractive) {
        Write-Host ''
        Write-Host '  No controlling TTY detected (agent shell, CI without a console, or' -ForegroundColor Cyan
        Write-Host '  redirected stdin) — auto-engaging -NonInteractive. Defaults will' -ForegroundColor Cyan
        Write-Host '  be used for every prompt. If the script aborts below for a missing' -ForegroundColor Cyan
        Write-Host '  required value, re-run in a real terminal OR pass that value as a' -ForegroundColor Cyan
        Write-Host '  parameter (see Get-Help .\install.ps1 -Full).' -ForegroundColor Cyan
    }
}

# -ForceTokens exists to PROMPT for replacement values; without a terminal the
# hidden Read-Host would read empty and Die confusingly at Step 3. Fail loud
# and early instead.
if ($ForceTokens -and $NonInteractive) {
    Die '-ForceTokens needs an interactive terminal — it must prompt for replacement token values. Re-run from a real PowerShell window (not an agent shell or CI).'
}

# ── Prompt helpers ──────────────────────────────────────────────────────────

function Read-PromptLine([string]$Question, [string]$Default) {
    if ($NonInteractive) { return $Default }
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "  $Question$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

function Read-PromptChoice([string]$Question, [string]$Default, [string[]]$Options) {
    if ($NonInteractive) { return $Default }
    Write-Host ''
    Write-Host "  $Question"
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $idx = $i + 1
        $marker = if ($Options[$i] -eq $Default) { '  (default)' } else { '' }
        Write-Host "    [$idx] $($Options[$i])$marker"
    }
    $answer = Read-Host '  > '
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    if ($answer -match '^\d+$') {
        $idx = [int]$answer - 1
        if ($idx -ge 0 -and $idx -lt $Options.Count) { return $Options[$idx] }
    }
    return $Default
}

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step([string]$Msg) {
    Write-Host ''
    Write-Host "▶ $Msg" -ForegroundColor Cyan
}
function Write-Ok([string]$Msg)    { Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-InfoMsg([string]$Msg) { Write-Host "  $Msg" }
function Write-WarnMsg([string]$Msg) { Write-Host "  ! $Msg" -ForegroundColor Yellow }
function Die([string]$Msg) {
    Write-Host ''
    Write-Host "✗ $Msg" -ForegroundColor Red
    exit 1
}

function Test-Command([string]$Name) {
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Append a line to $PROFILE only if not already present.
function Add-ProfileLine([string]$Line) {
    if (-not (Test-Path $PROFILE)) {
        New-Item -Type File -Force $PROFILE | Out-Null
    }
    $existing = Get-Content $PROFILE -ErrorAction SilentlyContinue
    if ($existing -and ($existing -contains $Line)) {
        Write-InfoMsg "already in `$PROFILE (skipped)"
    } else {
        Add-Content -Path $PROFILE -Value $Line
        Write-Ok "appended to `$PROFILE"
    }
}

# Append a line to ~/.npmrc only if not already present.
function Add-NpmrcLine([string]$Line) {
    $npmrc = Join-Path $env:USERPROFILE '.npmrc'
    if (-not (Test-Path $npmrc)) { New-Item -Type File -Force $npmrc | Out-Null }
    $existing = Get-Content $npmrc -ErrorAction SilentlyContinue
    if ($existing -and ($existing -contains $Line)) {
        Write-InfoMsg "already in .npmrc (skipped)"
    } else {
        Add-Content -Path $npmrc -Value $Line
        Write-Ok "appended to .npmrc"
    }
}

# Win32 CredRead/CredWrite via P/Invoke — same approach shield uses internally.
# Stores the secret in Windows Credential Manager without requiring the
# CredentialManager PowerShell module (which needs Install-Module and may be
# blocked by corp policy).
# PowerShell 7+ on .NET Core does NOT reference every System.* assembly by
# default when Add-Type compiles inline C#. Two specific references bit the
# previous version of this block on PS 7.6 (.NET 9):
#
#   1. `System.Runtime.InteropServices.ComTypes.FILETIME` — type-forwarded
#      in newer .NET; Roslyn in-process compile refuses it without an
#      explicit reference. We avoid the issue by inlining a private FILETIME
#      layout (two UInt32s — it's only there to consume layout bytes).
#   2. `System.ComponentModel.Win32Exception` — lives in
#      System.ComponentModel.Primitives which isn't in the Add-Type default
#      reference set. We throw a plain InvalidOperationException with the
#      Win32 error code instead.
#
# Both changes are semantic no-ops for the caller (the FILETIME field is
# never read; the thrown exception's message still contains the Win32 code).
#
# We guard Add-Type with a type-existence check so re-running install.ps1 in
# the same PowerShell session doesn't hit "type already defined" errors, and
# we use -ErrorAction Stop so a *real* compilation failure surfaces loudly
# with the CS#### diagnostic instead of silently moving on to the next step
# (which would then fail with a confusing "[Credman] is not a type" error).
if (-not ('CredmanV2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CredmanV2 {
    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
        public UInt32 Flags;
        public UInt32 Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
        public FILETIME LastWritten;
        public UInt32 CredentialBlobSize;
        public IntPtr CredentialBlob;
        public UInt32 Persist;
        public UInt32 AttributeCount;
        public IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, UInt32 type, UInt32 reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite([In] ref CREDENTIAL credential, UInt32 flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern void CredFree(IntPtr cred);

    public static string Read(string target) {
        IntPtr p;
        if (!CredRead(target, 1, 0, out p)) return null;
        try {
            var c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            if (c.CredentialBlobSize == 0) return "";
            var bytes = new byte[c.CredentialBlobSize];
            Marshal.Copy(c.CredentialBlob, bytes, 0, (int)c.CredentialBlobSize);
            return Encoding.Unicode.GetString(bytes);
        } finally { CredFree(p); }
    }

    public static void Write(string target, string secret) {
        var blob = Encoding.Unicode.GetBytes(secret);
        var ptr = Marshal.AllocCoTaskMem(blob.Length);
        try {
            Marshal.Copy(blob, 0, ptr, blob.Length);
            var c = new CREDENTIAL {
                Flags = 0,
                Type = 1,
                TargetName = target,
                CredentialBlobSize = (UInt32)blob.Length,
                CredentialBlob = ptr,
                Persist = 2,
                UserName = "forge"
            };
            if (!CredWrite(ref c, 0)) {
                throw new InvalidOperationException(
                    "CredWrite failed (Win32 error " + Marshal.GetLastWin32Error() + ")");
            }
        } finally { Marshal.FreeCoTaskMem(ptr); }
    }
}
'@ -ErrorAction Stop
}

# ── store_token_in_credman helper ────────────────────────────────────────────
# Reused for both FORGE_PACKAGE_TOKEN (step 3) and FORGE_ACCESS_TOKEN (step 6).
# Prompts (no-echo), writes to Credential Manager, emits profile line, and
# populates the current session's env var. Idempotent — reuses the stored
# credential if it already exists.

function Install-TokenInCredman([string]$VarName, [string]$Label) {
    # -ForceTokens must reach THIS reuse check, not just the backend-selection
    # gate in Step 2 — otherwise "force fresh token prompts" silently reuses
    # the stale stored value it exists to replace (field-reported: a 401ing
    # workstation re-ran with -ForceTokens and was never prompted).
    # CredWrite overwrites an existing entry with the same TargetName, so the
    # prompt path below doubles as the replace path.
    $existing = if ($ForceTokens) { $null } else { [CredmanV2]::Read($VarName) }
    if ($existing) {
        Write-InfoMsg "$VarName already in Credential Manager — reusing (pass -ForceTokens to replace)"
    } else {
        Write-InfoMsg "paste $Label (input hidden; will be stored in Credential Manager):"
        $secure = Read-Host -AsSecureString "  $VarName"
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if (-not $plain) { Die "empty $VarName" }
        [CredmanV2]::Write($VarName, $plain)
        Write-Ok "stored in Credential Manager under '$VarName'"
        $plain = $null
    }
    Add-ProfileLine "`$env:$VarName = [CredmanV2]::Read('$VarName')"
    Set-Item -Path "Env:$VarName" -Value ([CredmanV2]::Read($VarName))
}

function Install-TokenInGcp([string]$VarName, [string]$GcpSecret) {
    $envLine = "`$env:$VarName = (& gcloud secrets versions access latest --secret=$GcpSecret --project=$GcpProject 2>`$null)"
    Add-ProfileLine $envLine
    Set-Item -Path "Env:$VarName" -Value (& gcloud secrets versions access latest --secret=$GcpSecret --project=$GcpProject)
}

# ── 1Password helpers ───────────────────────────────────────────────────────
# Symmetric to the gcp helpers above. The token never enters this script's
# memory beyond the Set-Item call below — it lives in 1Password and is
# fetched via `op read` at every shell startup (the $PROFILE line).

function Test-OpInstalled {
    [bool](Get-Command op -ErrorAction SilentlyContinue)
}

function Test-OpAuthenticated {
    if (-not (Test-OpInstalled)) { return $false }
    try {
        $null = & op whoami 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Test-OpVaultItem {
    param([string]$Vault, [string]$Item, [string]$Field)
    try {
        $val = & op read "op://$Vault/$Item/$Field" 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        return -not [string]::IsNullOrEmpty($val)
    } catch { return $false }
}

# All-or-nothing — both items must resolve before we auto-select the
# onepassword backend. Prevents the case where a teammate has been
# granted the vault but only one of the two items was shared, which
# would otherwise strand them with one empty env var.
function Test-OpVaultAccess {
    param([string]$Vault, [string]$AccessItem, [string]$PackageItem, [string]$Field)
    if (-not (Test-OpAuthenticated)) { return $false }
    if (-not (Test-OpVaultItem -Vault $Vault -Item $AccessItem -Field $Field)) { return $false }
    if (-not (Test-OpVaultItem -Vault $Vault -Item $PackageItem -Field $Field)) { return $false }
    return $true
}

function Install-OpCli {
    if (Test-Command 'winget') {
        Write-InfoMsg 'installing 1Password CLI via winget...'
        winget install --id AgileBits.1Password.CLI -e --accept-package-agreements --accept-source-agreements | Out-Null
        # winget updates PATH but current session must refresh — same
        # pattern Step 1 uses after the nvm-windows install.
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not (Test-OpInstalled)) {
            Die '1Password CLI installed but op not on PATH. Close this PowerShell, open a fresh window, and re-run.'
        }
        Write-Ok '1Password CLI installed'
    } else {
        Die '1Password CLI (op) not installed and winget unavailable. Install op manually from https://developer.1password.com/docs/cli/get-started/, then re-run.'
    }
}

function Install-TokenInOnePassword([string]$VarName, [string]$ItemName) {
    $ref = "op://$OpVault/$ItemName/$OpField"
    $envLine = "`$env:$VarName = (& op read `"$ref`" 2>`$null)"
    Add-ProfileLine $envLine
    Set-Item -Path "Env:$VarName" -Value (& op read $ref 2>$null)
}

# Sweep stale Credential Manager entries when activating the onepassword
# backend so the keystore is never a second source of truth. Idempotent —
# missing entries silently no-op. Sweeps current names plus every retired
# token name per docs/as-built/forge-access-token-provenance.md:
#   FORGE_CODEX_TOKEN     — retired PR #230 (Forge Atlas rename)
#   ATLAS_INGEST_TOKEN    — retired PR #552 (Forge-prefix consistency)
#   CODEX_INGEST_TOKEN    — retired PR #544 (mechanical rename)
#   FORGE_INGEST_TOKEN    — current ingest token; sweep so a stale workstation
#                           value can't shadow the 1Password-sourced one.
# After each cmdkey /delete, re-read via CredmanV2 to verify the entry is
# actually gone — cmdkey can silently fail on some Persist=2 entries
# written via CredWrite directly (though never observed in the field).
function Clear-StaleKeystoreEntries {
    $sweepNames = @(
        $PatVar,
        $TokVar,
        'FORGE_CODEX_TOKEN',
        'forge:FORGE_CODEX_TOKEN',
        'ATLAS_INGEST_TOKEN',
        'CODEX_INGEST_TOKEN',
        'FORGE_INGEST_TOKEN'
    )
    foreach ($entryName in $sweepNames) {
        try {
            $existing = [CredmanV2]::Read($entryName)
            if ($existing) {
                & cmdkey /delete:$entryName *>$null
                $stillThere = [CredmanV2]::Read($entryName)
                if ($stillThere) {
                    Write-WarnMsg "cmdkey /delete:$entryName reported success but entry persists — inspect Credential Manager manually"
                } else {
                    Write-InfoMsg "swept stale Credential Manager entry: $entryName"
                }
            }
        } catch { }
    }
}

# ── Step 1: Node (>= repo minimum, install only if needed) ───────────────────
#
# We do NOT force an exact version on the client. If their Node already meets
# the minimum ($NODE_VERSION, which mirrors the repo's .nvmrc floor) we leave it
# untouched. Only when Node is missing or too old do we install $NODE_VERSION via
# nvm-windows. Claude Code runs the plugin's scripts under whatever Node is on
# PATH, so "new enough" is the only requirement — the marketplace install does
# the rest.

# Helper: safely read node version without tripping $ErrorActionPreference='Stop'.
function Get-NodeVersionSafe {
    if (-not (Test-Command 'node')) { return $null }
    try {
        $ver = & node --version 2>$null
        if ($LASTEXITCODE -eq 0) { return $ver }
    } catch { }
    return $null
}

# Version-floor test: $true when semver $Current >= $Minimum. A leading 'v' on
# either side is tolerated. PowerShell's [version] type does the comparison
# (the Windows analogue of install.sh's `sort -V` helper).
function Test-NodeVersionAtLeast([string]$Current, [string]$Minimum) {
    $c = $Current.TrimStart('v')
    $m = $Minimum.TrimStart('v')
    try {
        return ([version]$c -ge [version]$m)
    } catch {
        return $false
    }
}

Write-Step "Step 1 — Node (>= $NODE_VERSION)"

$existingNode = Get-NodeVersionSafe
if ($existingNode -and (Test-NodeVersionAtLeast $existingNode $NODE_VERSION)) {
    Write-Ok "Node $existingNode already satisfies the minimum (>= $NODE_VERSION) — leaving it"
} else {
    if ($existingNode) {
        Write-InfoMsg "Node $existingNode is below the required minimum $NODE_VERSION — installing via nvm-windows"
    } else {
        Write-InfoMsg "Node not found — installing $NODE_VERSION via nvm-windows"
    }

    if (-not (Test-Command 'nvm')) {
        Write-InfoMsg 'nvm-windows not found'
        if (Test-Command 'winget') {
            Write-InfoMsg 'installing via winget...'
            winget install CoreyButler.NVMforWindows --accept-package-agreements --accept-source-agreements | Out-Null
            # winget updates PATH but current session must refresh
            $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
            if (-not (Test-Command 'nvm')) {
                Die 'nvm installed but not on PATH. Close this PowerShell, open a fresh one, and re-run.'
            }
            Write-Ok 'nvm-windows installed'
        } else {
            Die 'nvm-windows not installed and winget unavailable. Install nvm-windows manually from https://github.com/coreybutler/nvm-windows/releases, then re-run.'
        }
    }

    $installed = & nvm list 2>$null | Select-String -Pattern ([regex]::Escape($NODE_VERSION)) -Quiet
    if (-not $installed) {
        Write-InfoMsg "installing Node $NODE_VERSION"
        & nvm install $NODE_VERSION | Out-Null
    }
    & nvm use $NODE_VERSION | Out-Null

    # Refresh PATH so the just-activated Node is visible to `node`/`npm`
    # invocations downstream in this session. Without this, `nvm use`
    # updates the symlink but the shell's PATH cache doesn't include
    # `C:\nvm4w\nodejs` until the next shell. Cheap and idempotent.
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')

    # NOTE: PowerShell variable names are case-INsensitive. This local must
    # not reuse the pin's name in lowercase — that is the SAME variable as
    # the script-level $NODE_VERSION pin, and assigning a value here would
    # clobber the pin. The distinct name $activeNode keeps them separate.
    $activeNode = Get-NodeVersionSafe
    if (-not $activeNode) {
        Die 'node not on PATH after nvm use + PATH refresh. Close this PowerShell, open a fresh one, and re-run the installer.'
    }
    if (-not (Test-NodeVersionAtLeast $activeNode $NODE_VERSION)) {
        Die "Node $activeNode active but the minimum is $NODE_VERSION. Run: nvm use $NODE_VERSION"
    }
    Write-Ok "Node $activeNode active (>= $NODE_VERSION)"
}

# ── Step 2: choose secrets backend ───────────────────────────────────────────
#
# Self-heal on re-run: if the user already has FORGE_PACKAGE_TOKEN AND
# FORGE_ACCESS_TOKEN in Windows Credential Manager (from a prior install),
# skip the backend prompt and auto-select `keystore`. This is what makes
# the installer idempotent — re-running `install.ps1` re-applies the
# prerequisites and re-runs the marketplace install with zero prompts.
# Without this auto-detect, even the idempotent `Install-TokenInCredman`
# path would still stop at the backend-choice prompt.
#
# -ForceTokens bypasses the detection for rotation / bad-token cases.

function Test-ExistingKeystoreTokens {
    try {
        $pkg = [CredmanV2]::Read($PatVar)
        $acc = [CredmanV2]::Read($TokVar)
        return ($pkg -and $acc)
    } catch {
        return $false
    }
}

if (-not $Secrets -and -not $ForceTokens) {
    if (Test-ExistingKeystoreTokens) {
        $Secrets = 'keystore'
        Write-Host ''
        Write-Host '  Detected existing FORGE_PACKAGE_TOKEN + FORGE_ACCESS_TOKEN' -ForegroundColor Cyan
        Write-Host '  in Windows Credential Manager — skipping backend prompt and' -ForegroundColor Cyan
        Write-Host '  token prompts. Running in HEAL mode (reusing stored tokens,' -ForegroundColor Cyan
        Write-Host '  sweeping stale state, reinstalling). Use -ForceTokens to' -ForegroundColor Cyan
        Write-Host '  rotate.' -ForegroundColor Cyan
    } elseif (Test-OpVaultAccess -Vault $OpVault -AccessItem $OpAccessItem -PackageItem $OpPackageItem -Field $OpField) {
        # Auto-detect onepassword AFTER keystore HEAL so existing keystore
        # users are never silently migrated. Detection requires (a) op
        # installed + signed in AND (b) both items resolve in the configured
        # vault — all-or-nothing avoids false positives that would strand
        # the user with empty env vars.
        $Secrets = 'onepassword'
        Write-Host ''
        Write-Host "  Detected 1Password CLI signed in and both FORGE_*_TOKEN items" -ForegroundColor Cyan
        Write-Host "  resolved in vault '$OpVault' — auto-selecting onepassword" -ForegroundColor Cyan
        Write-Host '  backend. Pass -Secrets keystore (or -ForceTokens to' -ForegroundColor Cyan
        Write-Host '  re-prompt) to override.' -ForegroundColor Cyan
    } else {
        $Secrets = Read-PromptChoice `
            'Where should the FORGE_PACKAGE_TOKEN and FORGE_ACCESS_TOKEN be stored?' `
            'keystore' `
            @('keystore', 'gcp', 'onepassword')
    }
}

Write-Step "Step 2 — secrets backend: $Secrets"

if ($Secrets -eq 'gcp') {
    if (-not (Test-Command 'gcloud')) {
        Die 'gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install'
    }
    $authed = (& gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>$null) | Where-Object { $_ }
    if (-not $authed) { Die 'gcloud not authenticated. Run: gcloud auth login' }
    Write-InfoMsg "gcloud authenticated as: $authed"

    if (-not $GcpProject) {
        $defaultProject = (& gcloud config get-value project 2>$null)
        $GcpProject = Read-PromptLine 'GCP project ID' $defaultProject
        if (-not $GcpProject) { Die 'GCP project ID is required under -Secrets gcp' }
    }

    Write-InfoMsg "GCP project:    $GcpProject"
    Write-InfoMsg "Package secret: $GcpPackageSecret"
    Write-InfoMsg "Access secret:  $GcpAccessSecret"

    foreach ($secret in @($GcpPackageSecret, $GcpAccessSecret)) {
        & gcloud secrets describe $secret --project=$GcpProject *>$null
        if ($LASTEXITCODE -ne 0) {
            Die "secret '$secret' not found in project '$GcpProject'. Create it first:
        'value' | gcloud secrets create $secret --data-file=- --project=$GcpProject"
        }
        Write-Ok "secret '$secret' exists in $GcpProject"
    }
}
elseif ($Secrets -eq 'onepassword') {
    # Setup chain: (1) install op via winget if missing; (2) verify desktop
    # CLI integration is enabled (op whoami succeeds); (3) info-banner the
    # vault/item/field configuration; (4) probe both items via op read
    # before any profile-line is written; (5) sweep stale Credential
    # Manager entries so the keystore is not a second source of truth.

    if (-not (Test-OpInstalled)) {
        Write-InfoMsg '1Password CLI (op) not found'
        if ($NonInteractive) {
            Die '1Password CLI not installed and -NonInteractive set. Install: winget install --id AgileBits.1Password.CLI -e'
        }
        $install = Read-PromptChoice 'Install 1Password CLI now (via winget)?' 'yes' @('yes', 'no')
        if ($install -eq 'yes') {
            Install-OpCli
        } else {
            Die '1Password CLI required for -Secrets onepassword. Aborting.'
        }
    }

    if (-not (Test-OpAuthenticated)) {
        Die @'
1Password CLI not authenticated.

  Fix:
    1. Open the 1Password desktop app -> Settings -> Developer ->
       enable "Integrate with 1Password CLI".
    2. On first integration the desktop app prompts for Windows Hello /
       system password — that prompt can only be answered in a real
       terminal session, NOT through Claude Code or another agent
       shell. If you launched this installer through an agent, exit and
       re-run from Windows Terminal / PowerShell directly.
    3. Verify in your shell:  op whoami
    4. Re-run this installer.
'@
    }

    Write-InfoMsg "1Password vault:  $OpVault"
    Write-InfoMsg "Access item:      $OpAccessItem"
    Write-InfoMsg "Package item:     $OpPackageItem"
    Write-InfoMsg "Field:            $OpField"

    foreach ($pair in @(
        @{ Item = $OpAccessItem;  Label = 'access token' },
        @{ Item = $OpPackageItem; Label = 'package token' }
    )) {
        if (-not (Test-OpVaultItem -Vault $OpVault -Item $pair.Item -Field $OpField)) {
            Die "op read 'op://$OpVault/$($pair.Item)/$OpField' returned empty. Check: vault name '$OpVault', item title '$($pair.Item)', field name '$OpField', and that the vault is shared with your 1Password account."
        }
        Write-Ok "item '$($pair.Item)' resolves in vault '$OpVault'"
    }

    Clear-StaleKeystoreEntries
}

# ── Step 3: FORGE_PACKAGE_TOKEN → env var ────────────────────────────────────

Write-Step "Step 3 — $PatVar → env var"

if ($Secrets -eq 'gcp') {
    Install-TokenInGcp $PatVar $GcpPackageSecret
}
elseif ($Secrets -eq 'onepassword') {
    Install-TokenInOnePassword $PatVar $OpPackageItem
}
else {
    # On a fresh machine the pwsh profile dir/file doesn't exist yet. Both the
    # legacy-block migration scan and the CredmanV2 injection below read and
    # write $PROFILE, and `Select-String -Path $PROFILE` throws an
    # ItemNotFoundException that -ErrorAction SilentlyContinue does NOT suppress
    # when the profile's parent directory is missing (observed on PS 7.x). Create
    # the file up front — New-Item -Force makes intermediate dirs — mirroring the
    # Add-ProfileLine guard above so every later read/write lands on a real file.
    if (-not (Test-Path $PROFILE)) {
        New-Item -Type File -Force $PROFILE | Out-Null
    }

    # Migration (forge-v0.5.28): earlier installer versions (<=0.5.27) emitted
    # a `# forge credman helper` block defining a type named `Credman` that
    # was either Read-only or shape-drifted from the installer's. When a
    # client upgraded, fresh PowerShell sessions loaded the Read-only
    # `Credman` from $PROFILE, the installer's re-run saw the type already
    # existed, skipped its own `Add-Type`, and then `[Credman]::Write` hit
    # "Method ... does not contain a method named 'Write'". The fix is a
    # clean rename: the installer and the new $PROFILE block both use
    # `CredmanV2`, which can't collide with the legacy type in an already-
    # loaded AppDomain. This migration strips the stale v1 block and its
    # stale `[Credman]::Read(...)` per-var lines from $PROFILE so future
    # fresh shells don't keep resurrecting the defunct type.
    if (Test-Path $PROFILE) {
        $profileLines = Get-Content -Path $PROFILE -ErrorAction SilentlyContinue
        if ($profileLines) {
            # Three-state parser: we're either 'normal', inside the legacy
            # helper block (between `# forge credman helper` and `"@`), or
            # waiting for the single line after `"@` that closes the outer
            # if-guard. We anchor on the here-string terminator rather than
            # counting `}` lines because the Credman C# inside the block
            # contains its own method/class braces that would otherwise
            # fool any depth-counting approach.
            $newLines = @()
            $state = 'normal'
            foreach ($profileLine in $profileLines) {
                if ($state -eq 'normal') {
                    if ($profileLine -match '^#\s*forge credman helper\s*$') {
                        # Enter legacy helper block — skip lines until the
                        # here-string terminator.
                        $state = 'inBlock'
                    }
                    elseif ($profileLine -match '\[Credman\]::Read\(') {
                        # Drop stale per-var line referencing the v1
                        # `Credman` type. New v2 lines use `CredmanV2`
                        # (written below) and stay.
                    }
                    else {
                        $newLines += $profileLine
                    }
                }
                elseif ($state -eq 'inBlock') {
                    # Here-string terminator `"@ ...` marks the tail of
                    # the legacy block; the next line is the outer `}`
                    # closing the if-guard.
                    if ($profileLine -match '^"@') { $state = 'afterHereString' }
                }
                elseif ($state -eq 'afterHereString') {
                    # Swallow exactly one more line (the outer `}`) then
                    # return to normal parsing. If the legacy block was
                    # malformed we may eat one extra line — acceptable
                    # tradeoff vs. more brittle anchoring.
                    $state = 'normal'
                }
            }
            if ($newLines.Count -ne $profileLines.Count) {
                Set-Content -Path $PROFILE -Value $newLines
                Write-Ok "migrated $PROFILE — removed legacy Credman helper + stale [Credman]::Read lines"
            }
        }
    }

    # Inject the CredmanV2 type definition into $PROFILE once, guarded so
    # we only compile it per shell session. Subsequent lines in $PROFILE
    # can then call [CredmanV2]::Read to populate env vars.
    $credmanGuard = '# forge credman helper v2'
    if (-not (Select-String -Path $PROFILE -Pattern $credmanGuard -SimpleMatch -Quiet -ErrorAction SilentlyContinue)) {
        # The $PROFILE-injected helper MUST mirror the installer's Credman
        # source EXACTLY — same struct layout, same FILETIME inlining, same
        # reference avoidance, AND same public method surface (Read + Write,
        # not just Read). Two reasons:
        #
        #   1. Compile-time: a shell that sources $PROFILE on startup must
        #      be able to compile the type under PS 7+ / .NET 9 without the
        #      ComTypes.FILETIME type-forwarding failure.
        #   2. Shape parity: if the helper defines a Read-only Credman, then
        #      ANY subsequent `Add-Type` guarded by
        #      `if (-not ('Credman' -as [type]))` will short-circuit — and
        #      the caller hits "[Credman] does not contain a method named
        #      'Write'" at the first Write. Observed on forge-v0.5.27 when
        #      a client opened a fresh PS 7 window between runs.
        #
        # Keeping the two definitions byte-identical (modulo here-string
        # escapes) avoids the class of bug entirely — any shell that loads
        # one of them ends up with the full interface.
        $credmanSource = @'
# forge credman helper v2
if (-not ('CredmanV2' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class CredmanV2 {
    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
        public UInt32 Flags;
        public UInt32 Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
        public FILETIME LastWritten;
        public UInt32 CredentialBlobSize;
        public IntPtr CredentialBlob;
        public UInt32 Persist;
        public UInt32 AttributeCount;
        public IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, UInt32 type, UInt32 reservedFlag, out IntPtr credentialPtr);
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite([In] ref CREDENTIAL credential, UInt32 flags);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern void CredFree(IntPtr cred);
    public static string Read(string target) {
        IntPtr p;
        if (!CredRead(target, 1, 0, out p)) return null;
        try {
            var c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            if (c.CredentialBlobSize == 0) return "";
            var bytes = new byte[c.CredentialBlobSize];
            Marshal.Copy(c.CredentialBlob, bytes, 0, (int)c.CredentialBlobSize);
            return Encoding.Unicode.GetString(bytes);
        } finally { CredFree(p); }
    }
    public static void Write(string target, string secret) {
        var blob = Encoding.Unicode.GetBytes(secret);
        var ptr = Marshal.AllocCoTaskMem(blob.Length);
        try {
            Marshal.Copy(blob, 0, ptr, blob.Length);
            var c = new CREDENTIAL {
                Flags = 0,
                Type = 1,
                TargetName = target,
                CredentialBlobSize = (UInt32)blob.Length,
                CredentialBlob = ptr,
                Persist = 2,
                UserName = "forge"
            };
            if (!CredWrite(ref c, 0)) {
                throw new InvalidOperationException(
                    "CredWrite failed (Win32 error " + Marshal.GetLastWin32Error() + ")");
            }
        } finally { Marshal.FreeCoTaskMem(ptr); }
    }
}
"@ -ErrorAction SilentlyContinue
}
'@
        Add-Content -Path $PROFILE -Value $credmanSource
        Write-Ok 'installed credman helper into $PROFILE'
    }
    Install-TokenInCredman $PatVar 'FORGE_PACKAGE_TOKEN (GitHub Packages read-access)'
}

$currentPat = (Get-Item "Env:$PatVar" -ErrorAction SilentlyContinue).Value
if (-not $currentPat) { Die "$PatVar empty after setup — check keystore/GCP/1Password configuration" }
Write-Ok "$PatVar populated (length=$($currentPat.Length))"

# ── Step 4: ~/.npmrc ─────────────────────────────────────────────────────────

Write-Step 'Step 4 — ~/.npmrc registry + auth'

Add-NpmrcLine "@bigbrainforge:registry=$RegistryUrl"
Add-NpmrcLine "//${RegistryHost}/:_authToken=`${$PatVar}"
Add-NpmrcLine 'always-auth=true'

# ── Step 5: FORGE_ACCESS_TOKEN → env var ──────────────────────────────────────

Write-Step "Step 5 — $TokVar → env var"

if ($Secrets -eq 'gcp') {
    Install-TokenInGcp $TokVar $GcpAccessSecret
}
elseif ($Secrets -eq 'onepassword') {
    Install-TokenInOnePassword $TokVar $OpAccessItem
}
else {
    Install-TokenInCredman $TokVar 'FORGE_ACCESS_TOKEN (Forge MCP endpoint)'
}

$currentTok = (Get-Item "Env:$TokVar" -ErrorAction SilentlyContinue).Value
if (-not $currentTok) {
    if ($Secrets -eq 'onepassword') {
        # Step 2 already verified the item resolved via op read. A
        # subsequent empty value here means op broke between Step 2
        # and Step 5 (desktop app re-locked, vault permission revoked,
        # field renamed mid-install). Die loudly — silent warn would
        # let the installer exit 0 with a non-functional access token.
        Die "$TokVar empty after 1Password read — op returned empty despite Step 2 vault probe succeeding. Check: 1Password desktop app is unlocked, vault access not revoked, item '$OpAccessItem' field '$OpField' not modified mid-install."
    }
    Write-WarnMsg "$TokVar not populated in this session (will be in new shells after `$PROFILE reload)"
}

# ── Step 6: install the plugin via Claude Code's marketplace ─────────────────
#
# The `claude` CLI does this non-interactively. `marketplace add` registers the
# public manifest (bigbrainforge/forge-installers); `plugin install forge@forge`
# pulls @bigbrainforge/forge-plugin from the private registry, authenticated by
# the FORGE_PACKAGE_TOKEN this script just put in the environment plus the
# ~/.npmrc reference. Claude Code's plugin system owns the install — nothing is
# copied into ~/.claude/ by this script. Both calls are non-fatal: a failure
# here (marketplace already added, or the package not yet published) leaves the
# prerequisites in place and prints the manual command to retry. Native exit
# codes do not trip $ErrorActionPreference='Stop', so $LASTEXITCODE is checked
# explicitly.

Write-Step "Step 6 — install the Forge plugin via Claude Code's marketplace"

if (Get-Command claude -ErrorAction SilentlyContinue) {
    & claude plugin marketplace add bigbrainforge/forge-installers
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'marketplace added: bigbrainforge/forge-installers'
    } else {
        Write-WarnMsg 'could not add marketplace (already added, or network/auth). Retry: claude plugin marketplace add bigbrainforge/forge-installers'
    }
    # First-party cooldown bypass (.forge/practices/first-party-publish-cooldown-bypass.md):
    # if the client's npm enforces a publish cooldown (min-release-age), `@latest`
    # resolves to a STALE pre-cooldown version for the first few days after a Forge
    # release. The marketplace installer's argv can't carry --min-release-age=0, so
    # scope the bypass to THIS first-party @bigbrainforge install via the npm env
    # config (it outranks both project and user .npmrc). Set + restored; never third-party.
    # Remove-Item is a cmdlet, so it does not clobber $LASTEXITCODE from `claude`.
    $env:npm_config_min_release_age = '0'
    try {
        & claude plugin install forge@forge
    } finally {
        Remove-Item Env:npm_config_min_release_age -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'installed plugin: forge@forge'
    } else {
        Write-WarnMsg 'could not install the plugin. Retry after launching Claude Code: npm_config_min_release_age=0 claude plugin install forge@forge'
    }
} else {
    Write-WarnMsg 'claude CLI not on PATH. Install Claude Code, then run:'
    Write-WarnMsg '    claude plugin marketplace add bigbrainforge/forge-installers'
    Write-WarnMsg '    claude plugin install forge@forge'
}

# ── Done ─────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '✓ Forge installed.' -ForegroundColor Green
Write-Host ''
Write-Host '  ! Required — load FORGE_PACKAGE_TOKEN and FORGE_ACCESS_TOKEN before using the plugin:' -ForegroundColor Yellow
Write-Host ''
Write-Host "    The installer appended env-var lines to: $PROFILE"
Write-Host '    Existing PowerShell sessions (including this one) do NOT have those'
Write-Host '    env vars set, and the plugin needs FORGE_ACCESS_TOKEN to reach your'
Write-Host '    Forge MCP endpoint. Either:'
Write-Host ''
Write-Host '      • Open a new PowerShell window, or' -ForegroundColor White
Write-Host "      • Run:  . `"$PROFILE`"" -ForegroundColor White
Write-Host ''
Write-Host '    Then verify both are populated:'
Write-Host '      "pkg=$($env:FORGE_PACKAGE_TOKEN.Length) access=$($env:FORGE_ACCESS_TOKEN.Length)"'
Write-Host '      # both lengths should be non-zero'
Write-Host ''
Write-Host '  Next:'
Write-Host "    1. Open a new PowerShell (or dot-source `"$PROFILE`") — see above."
Write-Host '    2. (Re)launch Claude Code from that shell so it loads the plugin + env vars.'
Write-Host '    3. Run:  /forge:help'
Write-Host '    4. Start your first goal:    /forge:goal "<your-objective>"'
Write-Host ''
Write-Host '  If the marketplace step above warned, re-run it once claude is on PATH:'
Write-Host '      claude plugin marketplace add bigbrainforge/forge-installers'
Write-Host '      claude plugin install forge@forge'
Write-Host ''
Write-Host '  Troubleshooting: see client-install.md, or re-run this installer —'
Write-Host '  it is idempotent.'

# forge release: forge-v3.2.3
