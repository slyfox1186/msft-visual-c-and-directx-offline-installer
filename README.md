# Microsoft Runtime Installer

A source-only PowerShell installer for current .NET SDKs, Visual C++ Redistributables, and the legacy DirectX End-User Runtimes.

This repository contains **no bundled Microsoft EXE, MSI, CAB, DLL, or ZIP files** and stores no Microsoft installer URLs. It downloads your selected packages directly from official Microsoft HTTPS sources, verifies them before they run, installs them unattended, and removes the temporary downloads afterward by default.

## What it installs

- The **latest stable .NET SDK** from every selected channel that Microsoft currently supports.
- The **latest supported Visual C++ v14 runtime**, plus the final Visual C++ 2005-2013 runtimes.
- The final **DirectX End-User Runtimes (June 2010)** for older games and applications that still require those legacy components.

The installer selects the correct packages for x86, x64, or ARM64 Windows automatically. On 64-bit Windows, it installs both x86 and x64 Visual C++ runtimes because 32-bit and 64-bit applications may require different packages.

DirectX June 2010 adds optional side-by-side components used by some older software. It does not replace the DirectX version included with Windows.

## Quick start

1. Open the Windows **Start** menu and search for **Command Prompt** (`cmd.exe`).
2. Select **Run as administrator**, then approve the Windows UAC prompt.
3. Paste the following line into the Administrator Command Prompt and press **Enter**:

```bat
start "Microsoft Runtime Installer" /max powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$msriSource=@(& curl.exe -fsS 'https://raw.githubusercontent.com/slyfox1186/msft-visual-c-and-directx-offline-installer/main/Start.ps1');if($LASTEXITCODE -ne 0 -or $msriSource.Count -eq 0){exit 1};try{$msriScript=[ScriptBlock]::Create($msriSource -join [Environment]::NewLine)}catch{exit 1};& $msriScript" && exit
```

A maximized Administrator PowerShell window opens, and Command Prompt closes.

## Using the installer

All package groups are enabled by default.

At the `Selection` prompt, use these controls. Press **Enter** after typing a key:

- `1`, `2`, or `3` turns a package group on or off.
- `4` or `5` lets you choose specific .NET channels or Visual C++ release families.
- `A` restores the default selection.
- `K` keeps the downloaded files instead of removing them afterward.
- `Q` cancels before installation.
- When you are ready to install, leave the prompt blank and press **Enter**.

Installation is unattended after confirmation. Microsoft progress windows may appear, but they require no clicks. The installer never restarts Windows automatically; it tells you when a manual restart is needed.

When installation finishes, the result screen shows what succeeded, whether temporary downloads were removed, and whether a restart is required. Press `R` to save an optional technical report, or press any other key to exit.

PowerShell 7 (`pwsh.exe`) is preferred automatically when it is available in `PATH`. Otherwise, the installer uses Windows PowerShell 5.1, which is included with Windows.

## Safety checks

- The launcher resolves the GitHub `main` branch to one validated commit, then downloads the required source files from that exact revision instead of using a repository archive.
- Source and package downloads require HTTPS, approved hosts, bounded redirects, timeouts, and automatic retries.
- The complete selected package plan is resolved before any package executable runs.
- .NET installers must match Microsoft's published SHA-512 hashes.
- Fixed Visual C++ and DirectX packages must match reviewed SHA-256 hashes.
- Visual C++ and DirectX executables must have valid Microsoft digital signatures.
- The rolling Visual C++ v14 package must also pass strict file-version checks and a reviewed minimum-version requirement.
- Malformed metadata, unexpected architectures, changed files, ambiguous matches, and unapproved hosts are rejected before execution.
- Temporary files use guarded, uniquely named workspaces whose paths are validated before cleanup.

You can review [Start.ps1](Start.ps1) and [Install.ps1](Install.ps1) before running the quick-start command. [Bootstrap.ps1](Bootstrap.ps1) is retained only for compatibility with older published commands.

## Advanced command-line use

Explicit component options bypass the interactive menu. These options are intended for automation or for users running a reviewed clone of the repository.

| Option | Values | Default | Purpose |
|---|---|---|---|
| `-Components` | `All`, `DotNet`, `VisualCpp`, `DirectX` | interactive | Select package groups |
| `-ExcludeComponents` | `DotNet`, `VisualCpp`, `DirectX` | none | Exclude package groups |
| `-DotNetChannels` | `All` or channels such as `8.0,10.0` | `All` | Select supported .NET channels |
| `-VisualCppVersions` | `All`, `2005`, `2008`, `2010`, `2012`, `2013`, `v14` | `All` | Select Visual C++ families |
| `-KeepDownloads` | switch | off | Keep Microsoft metadata and installer downloads |
| `-ReportPath` | folder or `.txt` path | none | Save a technical report |
| `-h`, `-Help`, `--help` | switch | off | Show help without elevation or network access |

Values are case-insensitive. Separate multiple values with commas. Use `All` by itself; duplicate values and filters for disabled components are rejected.

Examples from a cloned repository:

```powershell
# Open the interactive installer
pwsh.exe -NoLogo -NoProfile -File .\Install.ps1

# Install only .NET 8.0 and 10.0 SDKs
.\Install.ps1 -Components DotNet -DotNetChannels 8.0,10.0

# Install only Visual C++ 2013 and the latest v14 family
.\Install.ps1 -Components VisualCpp -VisualCppVersions 2013,v14

# Install everything except DirectX and keep the downloads
.\Install.ps1 -ExcludeComponents DirectX -KeepDownloads
```

Windows PowerShell 5.1 fallback:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

## Architecture selection

Architecture is detected automatically and cannot be overridden.

| Windows | .NET SDK | Visual C++ | DirectX |
|---|---|---|---|
| x86 | x86 | x86 | Architecture-neutral |
| x64 | x64 | x86 and x64 | Architecture-neutral |
| ARM64 | ARM64 | x86 and x64 compatibility packages | Architecture-neutral |

## Requirements

- Windows on x86, x64, or ARM64
- Administrator access
- Windows PowerShell 5.1 or PowerShell 7
- `curl.exe` available in `PATH`
- Internet access to GitHub and the approved Microsoft hosts
- Enough disk space for the selected SDKs and runtimes

`-ExecutionPolicy Bypass` applies only to the launched PowerShell process. It does not change the computer's saved execution policy.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | All selected packages completed successfully |
| `1` | Validation, download, verification, installation, or cleanup failed |
| `2` | Cancelled before package downloads |
| `3010` | Successful; Windows reports that a restart is required |

## Verification

The project has no build step. Run the offline help and configured static analysis before submitting changes:

```powershell
pwsh -NoProfile -File ./Install.ps1 -Help
pwsh -NoProfile -Command 'Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1'
```

Every `.ps1`, `.psm1`, and `.psd1` file should also be parsed before submission. Linux checks can verify parsing, help output, and static analysis, but they do not prove native Windows behavior. Use a disposable Windows environment to test UAC, Authenticode, installer switches, exit codes, cleanup, and console rendering.

## Feedback and problems

If something fails, save the technical report and include the failed package name and exit code in a [GitHub issue](https://github.com/slyfox1186/msft-visual-c-and-directx-offline-installer/issues).

## Project notes

This is the online GitHub edition. The separately maintained offline ZIP remains linked from the [original Reddit post](https://www.reddit.com/r/Batch/comments/1mwbttn/comment/p6iy6km/) and is not required by this version.

Microsoft owns and licenses the downloaded packages. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). This project is not affiliated with or endorsed by Microsoft.
