# forge-installers

Public installer scripts for **[@bigbrainforge/forge](https://github.com/bigbrainforge/forge)** (a private package on GitHub Packages).

This repo contains only the installer boilerplate — the scripts that bootstrap Node 22, write `~/.npmrc` auth, store secrets in your OS keystore or GCP Secret Manager, and run `npm install -g @bigbrainforge/forge`. No proprietary Forge code lives here; those artifacts are sealed and shipped via the private GitHub Packages registry.

## Install

Your BigBrain representative will send you:
- A `FORGE_PACKAGE_TOKEN` (GitHub Packages read-access token) — stored in your password manager
- A `FORGE_ACCESS_TOKEN` for your Forge MCP endpoint
- Your Forge MCP URL + assigned repo/project identifier

Then run, per platform:

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/bigbrainforge/forge-installers/main/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

### Windows (PowerShell)

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/bigbrainforge/forge-installers/main/install.ps1 -OutFile install.ps1
.\install.ps1
```

The installer prompts for your secrets backend (OS keystore or GCP Secret Manager) and guides you through the rest. See [`client-install.md`](./client-install.md) for the full guide including manual setup, GCP Secret Manager pre-population, and troubleshooting.

## Scripted / CI installs

```bash
# macOS/Linux
./install.sh --secrets=gcp --gcp-project=YOUR-PROJECT --non-interactive

# Windows
.\install.ps1 -Secrets gcp -GcpProject YOUR-PROJECT -NonInteractive
```

Full flags: `./install.sh --help` / `Get-Help .\install.ps1 -Full`.

## License

MIT — these installer scripts are published under the MIT license so clients can audit, modify, or fork them freely. The proprietary Forge runtime (sealed bytecode) has its own (non-open-source) license terms governed by your BigBrain contract.

## Support

- Install issues: contact your BigBrain representative with the output of the installer.
- Security concerns: security@bigbrainforge.com — do not file as public GitHub issues.
- The proprietary `@bigbrainforge/forge` package is tracked in the private repo; this repo is installer-only.
