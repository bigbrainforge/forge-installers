<#
.SYNOPSIS
    @bigbrainforge/forge-plugin — Windows installer.

.DESCRIPTION
    One-command client install for the Forge Claude Code plugin. Handles:
      - nvm-windows detection (installs via winget if available)
      - Node 22 LTS install + use
      - FORGE_PACKAGE_TOKEN storage (Windows Credential Manager or GCP Secret Manager)
      - .npmrc registry + auth config
      - npm install -g @bigbrainforge/forge-plugin
      - FORGE_ACCESS_TOKEN storage (same secrets backend)
      - PowerShell $PROFILE wiring
      - forge-plugin run (copies slash commands + statusline into ~/.claude/)
      - Plugin-file verification

    The plugin is a standalone artifact — it runs against the deployed Forge
    MCP server and does not require the `forge` CLI, codex, or shield to be
    installed locally. Claude Code must already be installed.

    Re-run is safe — all operations are idempotent.

.PARAMETER Secrets
    Where to store secrets. "keystore" = Windows Credential Manager (default).
    "gcp" = GCP Secret Manager via gcloud.

.PARAMETER GcpProject
    GCP project ID for Secret Manager (required when Secrets=gcp).

.PARAMETER GcpPackageSecret
    Secret name holding the FORGE_PACKAGE_TOKEN. Default: FORGE_PACKAGE_TOKEN.

.PARAMETER GcpAccessSecret
    Secret name holding FORGE_ACCESS_TOKEN. Default: FORGE_ACCESS_TOKEN.

.PARAMETER SkipVerify
    Skip the final plugin-file verification step.

.EXAMPLE
    .\install.ps1
    # interactive, Windows Credential Manager

.EXAMPLE
    .\install.ps1 -Secrets gcp -GcpProject my-proj
    # uses GCP Secret Manager with default secret names

.NOTES
    Pre-populate secrets in GCP before running with -Secrets gcp:
      "ghp_..."  | gcloud secrets create FORGE_PACKAGE_TOKEN  --data-file=- --project=PROJECT
      "mcp..."   | gcloud secrets create FORGE_ACCESS_TOKEN --data-file=- --project=PROJECT
#>

[CmdletBinding()]
param(
    # If not supplied, the installer prompts for this interactively.
    [ValidateSet('', 'keystore', 'gcp')]
    [string]$Secrets = '',

    # If not supplied under -Secrets gcp, the installer prompts for this.
    [string]$GcpProject = '',

    [string]$GcpPackageSecret = 'FORGE_PACKAGE_TOKEN',

    [string]$GcpAccessSecret = 'FORGE_ACCESS_TOKEN',

    [switch]$NonInteractive,

    [switch]$SkipVerify,

    # Force fresh token prompts even if existing tokens are detected in
    # Credential Manager or GCP. Use for rotation, or when the stored
    # tokens are known bad (e.g. 401 from GitHub Packages). Without this
    # flag the installer auto-detects and reuses existing tokens silently,
    # making re-runs a zero-prompt self-heal.
    [switch]$ForceTokens
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.2.0'
$NodeMajor = 22
$PackageName = '@bigbrainforge/forge-plugin'
$RegistryUrl = 'https://npm.pkg.github.com'
$RegistryHost = 'npm.pkg.github.com'
$PatVar = 'FORGE_PACKAGE_TOKEN'
$TokVar = 'FORGE_ACCESS_TOKEN'

# Legacy token names from pre-PR-#230 installs. If a client's Credential
# Manager has these but not the current names, the installer silently
# migrates (read-then-write-under-new-name-then-delete-old). Non-
# destructive — the secret is preserved, just stored under the canonical
# name. This is what lets a pilot re-run the installer with zero prompts
# even if their original install predates the rename.
$LegacyPatVar = 'GH_FORGE_PACKAGES_PAT'
$LegacyTokVar = 'FORGE_CODEX_TOKEN'

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
    $existing = [CredmanV2]::Read($VarName)
    if ($existing) {
        Write-InfoMsg "$VarName already in Credential Manager — reusing"
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
    $line = "`$env:$VarName = (& gcloud secrets versions access latest --secret=$GcpSecret --project=$GcpProject 2>`$null)"
    Add-ProfileLine $line
    Set-Item -Path "Env:$VarName" -Value (& gcloud secrets versions access latest --secret=$GcpSecret --project=$GcpProject)
}

# ── Step 1: Node 22 via nvm-windows ──────────────────────────────────────────
#
# Fast path: if Node $NodeMajor is already on PATH and working, skip nvm
# entirely. Clients with their own Node install (MSI, corp-managed, or
# an nvm4w setup that's already active in this shell) don't need us to
# touch their Node setup. This is what makes re-running the installer
# non-destructive for healthy installs.
#
# Slow path: install nvm-windows via winget, install Node $NodeMajor
# via nvm, activate it, then refresh $env:Path from system env vars so
# the NEW Node install is visible to the REST of this PowerShell
# session. Without the PATH refresh, every subsequent `node` / `npm`
# invocation would fail with "term not recognized" under
# $ErrorActionPreference='Stop' and terminate the script. The refresh
# is the same trick we use after winget-install nvm itself.

# Helper: safely read node version without tripping $ErrorActionPreference='Stop'.
function Get-NodeVersionSafe {
    if (-not (Test-Command 'node')) { return $null }
    try {
        $ver = & node --version 2>$null
        if ($LASTEXITCODE -eq 0) { return $ver }
    } catch { }
    return $null
}

Write-Step "Step 1 — Node $NodeMajor LTS"

$existingNode = Get-NodeVersionSafe
if ($existingNode -and $existingNode.StartsWith("v$NodeMajor")) {
    Write-Ok "Node $existingNode already active — skipping nvm (re-run safe, nothing to install)"
} else {
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

    $installed = & nvm list 2>$null | Select-String "\b$NodeMajor\." -Quiet
    if (-not $installed) {
        Write-InfoMsg "installing Node $NodeMajor LTS"
        & nvm install $NodeMajor | Out-Null
    }
    & nvm use $NodeMajor | Out-Null

    # Refresh PATH so the just-activated Node is visible to `node`/`npm`
    # invocations downstream in this session. Without this, `nvm use`
    # updates the symlink but the shell's PATH cache doesn't include
    # `C:\nvm4w\nodejs` until the next shell. Cheap and idempotent.
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')

    $nodeVersion = Get-NodeVersionSafe
    if (-not $nodeVersion) {
        Die 'node not on PATH after nvm use + PATH refresh. Close this PowerShell, open a fresh one, and re-run the installer.'
    }
    if (-not $nodeVersion.StartsWith("v$NodeMajor")) { Die "expected Node $NodeMajor, got $nodeVersion" }
    Write-Ok "Node $nodeVersion active"
}

# ── Step 2: choose secrets backend ───────────────────────────────────────────
#
# Self-heal on re-run: if the user already has FORGE_PACKAGE_TOKEN AND
# FORGE_ACCESS_TOKEN in Windows Credential Manager (from a prior install),
# skip the backend prompt and auto-select `keystore`. This is what makes
# the installer idempotent — a pilot client hitting the pre-0.6.0 bin-shim
# collision can re-run `install.ps1` with zero prompts and the installer
# heals the state (sweeps shims, reinstalls scoped package, nukes stale
# command markdown, re-runs postinstall). Without this auto-detect, even
# the idempotent `Install-TokenInCredman` path would still stop at the
# backend-choice prompt.
#
# -ForceTokens bypasses the detection for rotation / bad-token cases.

function Migrate-LegacyCredmanEntry([string]$LegacyName, [string]$CurrentName) {
    # Non-destructive migration: if a legacy-named token exists in
    # Credential Manager but the current-named one does not, copy the
    # value across under the new name. The legacy entry is left in
    # place (harmless, unused from here on) so we don't risk data loss
    # from a failed write. Returns $true if a migration was performed.
    try {
        $existingCurrent = [CredmanV2]::Read($CurrentName)
        if ($existingCurrent) { return $false }  # current name already has a value
        $legacyValue = [CredmanV2]::Read($LegacyName)
        if (-not $legacyValue) { return $false } # no legacy value either
        [CredmanV2]::Write($CurrentName, $legacyValue)
        Write-InfoMsg "migrated $LegacyName -> $CurrentName in Credential Manager (legacy entry left in place, harmless)"
        return $true
    } catch {
        return $false
    }
}

function Test-ExistingKeystoreTokens {
    # First migrate any legacy-named entries to current names. This is
    # idempotent and non-destructive for clients whose keystore already
    # uses the current names. After migration, check for current names.
    try {
        Migrate-LegacyCredmanEntry $LegacyPatVar $PatVar | Out-Null
        Migrate-LegacyCredmanEntry $LegacyTokVar $TokVar | Out-Null
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
    } else {
        $Secrets = Read-PromptChoice `
            'Where should the FORGE_PACKAGE_TOKEN and FORGE_ACCESS_TOKEN be stored?' `
            'keystore' `
            @('keystore', 'gcp')
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

# ── Step 3: FORGE_PACKAGE_TOKEN → env var ────────────────────────────────────

Write-Step "Step 3 — $PatVar → env var"

if ($Secrets -eq 'gcp') {
    Install-TokenInGcp $PatVar $GcpPackageSecret
}
else {
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
            foreach ($line in $profileLines) {
                if ($state -eq 'normal') {
                    if ($line -match '^#\s*forge credman helper\s*$') {
                        # Enter legacy helper block — skip lines until the
                        # here-string terminator.
                        $state = 'inBlock'
                    }
                    elseif ($line -match '\[Credman\]::Read\(') {
                        # Drop stale per-var line referencing the v1
                        # `Credman` type. New v2 lines use `CredmanV2`
                        # (written below) and stay.
                    }
                    else {
                        $newLines += $line
                    }
                }
                elseif ($state -eq 'inBlock') {
                    # Here-string terminator `"@ ...` marks the tail of
                    # the legacy block; the next line is the outer `}`
                    # closing the if-guard.
                    if ($line -match '^"@') { $state = 'afterHereString' }
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
if (-not $currentPat) { Die "$PatVar empty after setup — check keystore/GCP configuration" }
Write-Ok "$PatVar populated (length=$($currentPat.Length))"

# ── Step 4: ~/.npmrc ─────────────────────────────────────────────────────────

Write-Step 'Step 4 — ~/.npmrc registry + auth'

Add-NpmrcLine "@bigbrainforge:registry=$RegistryUrl"
Add-NpmrcLine "//${RegistryHost}/:_authToken=`${$PatVar}"
Add-NpmrcLine 'always-auth=true'

# ── Step 5: npm install ──────────────────────────────────────────────────────

Write-Step "Step 5 — install $PackageName"

# Cleanup prior installs that collide on the `forge-plugin` bin name.
#
# Two scenarios we defend against:
#   1. The client previously installed the deprecated public `forge-plugin@*`
#      package from npmjs.com (pre-PR #230). That package declares
#      `"bin": { "forge-plugin": ... }` identical to the new
#      `@bigbrainforge/forge-plugin`, so npm refuses with EEXIST when it
#      tries to write the new shim over the old one.
#   2. A prior run of this installer crashed mid-install (see the
#      forge-v0.5.25 Credman bug) and left a partial `@bigbrainforge/forge-plugin`
#      global install with bin shims but inconsistent metadata — npm treats
#      that as EEXIST too.
#
# Both `npm uninstall -g` calls are idempotent: they print a warning and
# exit 0 if the package isn't installed, which is exactly what we want.
# We still sweep the bare bin shim as a belt-and-suspenders fallback for
# the case where uninstall leaves the shim behind (observed when the
# package's lib dir was manually removed before uninstall ran).
Write-InfoMsg 'Removing any stale forge-plugin shims from prior installs...'
& npm uninstall -g forge-plugin --silent 2>$null | Out-Null
& npm uninstall -g $PackageName --silent 2>$null | Out-Null

$npmPrefix = (& npm config get prefix 2>$null).Trim()
if ($npmPrefix) {
    foreach ($leaf in @('forge-plugin', 'forge-plugin.cmd', 'forge-plugin.ps1')) {
        $stale = Join-Path $npmPrefix $leaf
        if (Test-Path -LiteralPath $stale) {
            try {
                Remove-Item -LiteralPath $stale -Force -ErrorAction Stop
                Write-InfoMsg "removed stale shim: $stale"
            } catch {
                Write-WarnMsg "could not remove $stale — npm install may fail with EEXIST: $($_.Exception.Message)"
            }
        }
    }
}

& npm install -g $PackageName --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { Die 'npm install failed — see output above' }
Write-Ok "installed $PackageName"

# ── Step 6: FORGE_ACCESS_TOKEN → env var ──────────────────────────────────────

Write-Step "Step 6 — $TokVar → env var"

if ($Secrets -eq 'gcp') {
    Install-TokenInGcp $TokVar $GcpAccessSecret
}
else {
    Install-TokenInCredman $TokVar 'FORGE_ACCESS_TOKEN (Forge MCP endpoint)'
}

$currentTok = (Get-Item "Env:$TokVar" -ErrorAction SilentlyContinue).Value
if (-not $currentTok) {
    Write-WarnMsg "$TokVar not populated in this session (will be in new shells after `$PROFILE reload)"
}

# ── Step 6.5: BurntToast for auto-update notifications (Windows only) ────────
# The plugin's Stop hook (auto-update-if-eligible.js) emits OS toast
# notifications after auto-installing a new plugin release ("restart
# Claude Code to load X.Y.Z"). macOS uses built-in `osascript`; on
# Windows the notifier shells out to `New-BurntToastNotification`,
# which requires the BurntToast PowerShell module. Install here,
# per-user, no admin — same pattern the claude-Win11-notifications
# skill uses. Idempotent: re-runs are a no-op because `-Force` is
# paired with Get-Module check below.
#
# Failure modes (corp policy blocks PSGallery, proxy issues, etc.)
# degrade gracefully: the plugin statusline still nudges via its
# cyan "<current>-><target>" segment; only the toast layer is lost.

Write-Step 'Step 6.5 — BurntToast for Windows toast notifications'

if (Get-Module -ListAvailable -Name BurntToast) {
    Write-Ok 'BurntToast already installed'
} else {
    try {
        Install-Module -Name BurntToast -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Ok 'BurntToast installed (CurrentUser scope)'
    } catch {
        Write-WarnMsg "BurntToast install failed: $($_.Exception.Message)"
        Write-WarnMsg '  Auto-update statusline nudge will still work; only OS toasts are lost.'
        Write-WarnMsg '  To retry later: pwsh -Command "Install-Module -Name BurntToast -Scope CurrentUser -Force"'
    }
}

# ── Step 6.9: nuke stale plugin state before postinstall ─────────────────────
# Belt-and-suspenders for the pre-0.6.0 bin-shim collision trap.
#
# Scenario: a client on <= 0.5.29 runs install.ps1 to heal a broken
# install. Step 5 already swept both packages + shims and installed a
# fresh scoped @bigbrainforge/forge-plugin. But ~/.claude/commands/forge/
# still contains the STALE setup.md / help.md / new.md / etc. from the
# deprecated 0.5.x binary that wrote them. install.js's `copyDir` does
# overwrite matching files, but any file present in the OLD tree yet
# absent in the NEW one would linger — and for upgrades across major-
# structure changes, the safest default is to start empty.
#
# We also clear ~/.claude/forge/VERSION + update-state.json so the
# postinstall writes them from scratch (the v0.6.0+ install.js reads
# package.json's version correctly, but clearing the old file eliminates
# any chance of a reader picking up a stale cached value from a prior
# session that held a file handle).
#
# ~/.claude/forge/bin/ is replaced by install.js's copy loop on every
# run, so we let it handle that to avoid interfering with any running
# Node process holding a file handle. Backups (~/.claude/forge/backup/)
# are left intact — they're rollback material, not stale state.

Write-Step 'Step 6.9 — clear stale plugin state (idempotent re-run safety)'

$claudeDir = Join-Path $env:USERPROFILE '.claude'
$forgeDir = Join-Path $claudeDir 'forge'
$cmdsDir = Join-Path $claudeDir 'commands\forge'

foreach ($stalePath in @(
    $cmdsDir,
    (Join-Path $forgeDir 'VERSION'),
    (Join-Path $forgeDir 'update-state.json')
)) {
    if (Test-Path -LiteralPath $stalePath) {
        try {
            Remove-Item -LiteralPath $stalePath -Recurse -Force -ErrorAction Stop
            Write-Ok "cleared $stalePath"
        } catch {
            Write-WarnMsg "could not clear $stalePath (the postinstall will overwrite): $($_.Exception.Message)"
        }
    }
}

# ── Step 7: run forge-plugin ─────────────────────────────────────────────────
# Copies slash commands, hooks, statusline, and utility scripts into
# ~/.claude/. Also registers the MCP server with Claude Code's config.

Write-Step 'Step 7 — Claude Code plugin → ~/.claude/'

if (Test-Command 'forge-plugin') {
    & forge-plugin
    if ($LASTEXITCODE -ne 0) {
        Die 'forge-plugin install exited with non-zero status'
    }
    Write-Ok 'plugin installed to ~/.claude/'
} else {
    Die 'forge-plugin binary not on PATH after npm install. Check: npm config get prefix'
}

# ── Step 8: verify plugin files ──────────────────────────────────────────────

if ($SkipVerify) {
    Write-Step 'Step 8 — verify (skipped by flag)'
} else {
    Write-Step 'Step 8 — verify'
    $claudeHome = Join-Path $env:USERPROFILE '.claude'
    $newCmd = Join-Path $claudeHome 'commands\forge\new.md'
    $versionFile = Join-Path $claudeHome 'forge\VERSION'
    if (-not (Test-Path $newCmd)) {
        Die "$newCmd missing — plugin install did not complete"
    }
    Write-Ok "slash commands installed at $(Join-Path $claudeHome 'commands\forge')"
    if (-not (Test-Path $versionFile)) {
        Die "$versionFile missing — plugin install did not complete"
    }
    $ver = Get-Content $versionFile
    Write-Ok "plugin VERSION: $ver"
}

# ── Done ─────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '✓ Forge plugin installed successfully.' -ForegroundColor Green
Write-Host ''
Write-Host '  ! Required next step — load FORGE_PACKAGE_TOKEN and FORGE_ACCESS_TOKEN:' -ForegroundColor Yellow
Write-Host ''
Write-Host "    The installer appended env-var lines to: $PROFILE"
Write-Host '    Existing PowerShell sessions (including this one) do NOT have'
Write-Host '    those env vars set. Before launching Claude Code, either:'
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
Write-Host '    2. Launch Claude Code from that shell so it inherits the env vars.'
Write-Host '    3. In Claude Code, run:  /forge:help'
Write-Host '    4. Start your first session:  /forge:new'
Write-Host ''
Write-Host '  The plugin runs against your Forge MCP endpoint. No local CLI needed —'
Write-Host '  codex indexing is handled centrally by the Forge team.'
Write-Host ''
Write-Host '  Troubleshooting: see client-install.md, or re-run this installer —'
Write-Host '  it is idempotent.'
