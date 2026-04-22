<#
.SYNOPSIS
    @bigbrainforge/forge — Windows installer.

.DESCRIPTION
    One-command client install. Handles:
      - nvm-windows detection (installs via winget if available)
      - Node 22 LTS install + use
      - FORGE_PACKAGE_TOKEN storage (Windows Credential Manager or GCP Secret Manager)
      - .npmrc registry + auth config
      - npm install -g @bigbrainforge/forge
      - FORGE_ACCESS_TOKEN storage (same secrets backend)
      - PowerShell $PROFILE wiring
      - Smoke test

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

.PARAMETER SkipSmokeTest
    Skip the final 'forge --version' verification.

.EXAMPLE
    .\install.ps1
    # interactive, Windows Credential Manager

.EXAMPLE
    .\install.ps1 -Secrets gcp -GcpProject my-proj
    # uses GCP Secret Manager with default secret names

.NOTES
    Pre-populate secrets in GCP before running with -Secrets gcp:
      "ghp_..."  | gcloud secrets create FORGE_PACKAGE_TOKEN  --data-file=- --project=PROJECT
      "codex..." | gcloud secrets create FORGE_ACCESS_TOKEN --data-file=- --project=PROJECT
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

    [switch]$SkipSmokeTest,

    [switch]$SkipPlugin
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.1.0'
$NodeMajor = 22
$PackageName = '@bigbrainforge/forge'
$RegistryUrl = 'https://npm.pkg.github.com'
$RegistryHost = 'npm.pkg.github.com'
$PatVar = 'FORGE_PACKAGE_TOKEN'
$TokVar = 'FORGE_ACCESS_TOKEN'

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
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Credman {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
        public UInt32 Flags;
        public UInt32 Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
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
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
        } finally { Marshal.FreeCoTaskMem(ptr); }
    }
}
'@ -ErrorAction SilentlyContinue

# ── Step 1: Node 22 via nvm-windows ──────────────────────────────────────────

Write-Step "Step 1 — Node $NodeMajor LTS"

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

$nodeVersion = (node --version) 2>$null
if (-not $nodeVersion) { Die 'node not on PATH after nvm use — open a fresh PowerShell and re-run' }
if (-not $nodeVersion.StartsWith("v$NodeMajor")) { Die "expected Node $NodeMajor, got $nodeVersion" }
Write-Ok "Node $nodeVersion active"

# ── Step 2: choose secrets backend ───────────────────────────────────────────

if (-not $Secrets) {
    $Secrets = Read-PromptChoice `
        'Where should the FORGE_PACKAGE_TOKEN and FORGE_ACCESS_TOKEN be stored?' `
        'keystore' `
        @('keystore', 'gcp')
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

    Write-InfoMsg "GCP project:  $GcpProject"
    Write-InfoMsg "Package secret:   $GcpPackageSecret"
    Write-InfoMsg "Codex secret: $GcpAccessSecret"

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

Write-Step "Step 3 — FORGE_PACKAGE_TOKEN → env var"

if ($Secrets -eq 'gcp') {
    $line = "`$env:$PatVar = (& gcloud secrets versions access latest --secret=$GcpPackageSecret --project=$GcpProject 2>`$null)"
    Add-ProfileLine $line
    Set-Item -Path "Env:$PatVar" -Value (& gcloud secrets versions access latest --secret=$GcpPackageSecret --project=$GcpProject)
}
else {
    $existing = [Credman]::Read($PatVar)
    if ($existing) {
        Write-InfoMsg 'FORGE_PACKAGE_TOKEN already in Credential Manager — reusing'
    } else {
        Write-InfoMsg 'paste FORGE_PACKAGE_TOKEN (input hidden; will be stored in Credential Manager):'
        $secure = Read-Host -AsSecureString '  FORGE_PACKAGE_TOKEN'
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if (-not $plain) { Die 'empty FORGE_PACKAGE_TOKEN' }
        [Credman]::Write($PatVar, $plain)
        Write-Ok "stored in Credential Manager under '$PatVar'"
        $plain = $null
    }
    # Inject the Credman type definition into $PROFILE once, guarded so we
    # only compile it per shell session (not per Add-Type call). Subsequent
    # lines in $PROFILE can then call [Credman]::Read to populate env vars.
    $credmanGuard = '# forge credman helper'
    if (-not (Select-String -Path $PROFILE -Pattern $credmanGuard -SimpleMatch -Quiet -ErrorAction SilentlyContinue)) {
        $credmanSource = @'
# forge credman helper
if (-not ('Credman' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Credman {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
        public UInt32 Flags;
        public UInt32 Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
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
}
"@ -ErrorAction SilentlyContinue
}
'@
        Add-Content -Path $PROFILE -Value $credmanSource
        Write-Ok 'installed credman helper into $PROFILE'
    }
    Add-ProfileLine "`$env:$PatVar = [Credman]::Read('$PatVar')"
    Set-Item -Path "Env:$PatVar" -Value ([Credman]::Read($PatVar))
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
Write-InfoMsg '(this downloads ~9 MB compressed + tree-sitter grammar prebuilds)'
& npm install -g $PackageName --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { Die 'npm install failed — see output above' }
Write-Ok "installed $PackageName"

# ── Step 6: FORGE_ACCESS_TOKEN → env var ──────────────────────────────────────

Write-Step "Step 6 — $TokVar → env var"

if ($Secrets -eq 'gcp') {
    $line = "`$env:$TokVar = (& gcloud secrets versions access latest --secret=$GcpAccessSecret --project=$GcpProject 2>`$null)"
    Add-ProfileLine $line
    Set-Item -Path "Env:$TokVar" -Value (& gcloud secrets versions access latest --secret=$GcpAccessSecret --project=$GcpProject)
}
else {
    $existing = [Credman]::Read($TokVar)
    if ($existing) {
        Write-InfoMsg 'token already in Credential Manager — reusing'
    } else {
        Write-InfoMsg "running 'forge shield fix shell-secret $TokVar' (prompt follows)"
        & forge shield fix shell-secret $TokVar
        if ($LASTEXITCODE -ne 0) { Die 'shield fix shell-secret failed' }
    }
    Add-ProfileLine "`$env:$TokVar = [Credman]::Read('$TokVar')"
    Set-Item -Path "Env:$TokVar" -Value ([Credman]::Read($TokVar))
}

$currentTok = (Get-Item "Env:$TokVar" -ErrorAction SilentlyContinue).Value
if (-not $currentTok) {
    Write-WarnMsg "$TokVar not populated in this session (will be in new shells after `$PROFILE reload)"
}

# ── Step 7: install Claude Code plugin (slash commands + statusline) ─────────

Write-Step 'Step 7 — Claude Code plugin → ~/.claude/'

if ($SkipPlugin) {
    Write-InfoMsg 'skipped (-SkipPlugin)'
} else {
    if (Test-Command 'forge-plugin') {
        & forge-plugin
        if ($LASTEXITCODE -ne 0) {
            Write-WarnMsg 'forge-plugin install exited with non-zero status'
        } else {
            Write-Ok 'plugin installed to ~/.claude/'
        }
    } else {
        Write-WarnMsg 'forge-plugin binary not on PATH. Run manually: forge-plugin'
    }
}

# ── Step 8: smoke test ───────────────────────────────────────────────────────

if ($SkipSmokeTest) {
    Write-Step 'Step 8 — smoke test (skipped by flag)'
} else {
    Write-Step 'Step 8 — smoke test'
    $v = (& forge --version) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $v) { Die 'forge --version failed — install did not succeed' }
    Write-Ok "forge $v is on PATH"
    & forge codex --help *>$null
    if ($LASTEXITCODE -ne 0) { Die 'forge codex --help failed' }
    Write-Ok 'codex subcommand loads cleanly'
}

# ── Done ─────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '✓ forge installed successfully.' -ForegroundColor Green
Write-Host ''
Write-Host "  Profile updated: $PROFILE"
Write-Host '  Open a new PowerShell (or dot-source $PROFILE) to pick up env vars.'
Write-Host ''
Write-Host '  Next:'
Write-Host '    forge --help                                    # top-level usage'
Write-Host '    forge codex index --csharp-root <path>          # index a codebase'
Write-Host '    forge codex index --csharp-root <path> --push <mcp-url> --repo-id <id>'
Write-Host ''
Write-Host '  Troubleshooting: see docs/client-install.md in the forge-cli package, or'
Write-Host '  re-run this installer — it is idempotent.'
