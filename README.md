# Microsoft Runtime Installer

Secure, architecture-aware PowerShell installer that downloads, verifies, and installs current .NET SDKs, Visual C++ Redistributables, and DirectX legacy runtimes unattended—with automatic cleanup.

> This is the online GitHub edition. No Microsoft installers or payload URLs are stored in the repository; its name is retained for continuity with the original offline project.

## Quick start

1. Open the Windows **Start** menu and search for **Command Prompt**.
2. Select **Run as administrator** and approve the Windows UAC prompt.
3. Paste this command into the Administrator Command Prompt and press **Enter**:

```bat
start "Microsoft Runtime Installer" /max powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$msriSource=@(& curl.exe -fsS 'https://raw.githubusercontent.com/slyfox1186/msft-visual-c-and-directx-offline-installer/main/Start.ps1');if($LASTEXITCODE -ne 0 -or $msriSource.Count -eq 0){exit 1};try{$msriScript=[ScriptBlock]::Create($msriSource -join [Environment]::NewLine)}catch{exit 1};& $msriScript" && exit
```

A maximized PowerShell window opens with every package group selected by default. Adjust the selection if needed, then press **Enter**. Downloads, verification, and installation continue unattended; visible Microsoft installer windows require no clicks. Windows is never restarted automatically.

PowerShell 7 (`pwsh.exe`) is preferred when available in `PATH`; otherwise the installer uses Windows PowerShell 5.1.

## Packages and version policy

| Package | Version selected at runtime | Verification |
|---|---|---|
| .NET SDK | Latest stable SDK from each selected, currently supported LTS or STS channel | Microsoft-published SHA-512 |
| Visual C++ 2005–2013 | Final release for each selected legacy family | Reviewed SHA-256 and Microsoft Authenticode |
| Visual C++ v14 | Latest supported x86 and x64 release from Microsoft’s official aliases | Microsoft Authenticode and file-version security floor |
| DirectX End-User Runtimes | Final June 2010 legacy release | Reviewed SHA-256 and Microsoft Authenticode |

Preview and end-of-support .NET channels are excluded. Rolling package versions are not pinned in the repository, and fixed legacy package locations are resolved from Microsoft at runtime. DirectX June 2010 supplies optional side-by-side components used by some older games and applications; it does not replace the DirectX version included with Windows.

## Package selection

| Key | Action |
|---:|---|
| `1` | Toggle .NET SDKs |
| `2` | Toggle Visual C++ Redistributables |
| `3` | Toggle DirectX June 2010 |
| `4` | Choose supported .NET SDK channels |
| `5` | Choose Visual C++ release families |
| `A` | Restore the default selection |
| `K` | Keep downloaded files instead of deleting them |
| **Enter** | Install the selected packages |
| `Q` | Cancel before installation |

Temporary downloads are removed by default, including after a failure. The final screen summarizes completed packages, failures, cleanup, elapsed time, and restart requirements. Press `R` to save an optional developer/IT report under `%USERPROFILE%`, or press any other key to exit.

## Security model

- Resolves the GitHub `main` branch to one validated commit, then downloads the required source files individually from that immutable revision—never a repository archive.
- Requires HTTPS, approved initial and effective hosts, bounded redirects, timeouts, and automatic retries.
- Resolves the complete selected Microsoft source plan before any package executable runs.
- Verifies .NET SDKs against SHA-512 hashes from Microsoft release metadata.
- Verifies fixed Visual C++ and DirectX packages against reviewed SHA-256 hashes.
- Requires valid Microsoft Corporation Authenticode signatures for Visual C++ and DirectX executables; Visual C++ v14 must also satisfy a reviewed minimum version.
- Rejects malformed metadata, ambiguous matches, unexpected architectures, changed files, and unapproved hosts before execution.
- Uses a guarded, GUID-named `%TEMP%` workspace and validates its path before recursive cleanup.

Review [Start.ps1](Start.ps1) and [Install.ps1](Install.ps1) before running the command if you prefer to audit the source first. [Bootstrap.ps1](Bootstrap.ps1) is retained only for compatibility with older published commands.

## Architecture selection

Architecture is detected automatically and cannot be overridden.

| Windows | .NET SDK | Visual C++ | DirectX |
|---|---|---|---|
| x86 | x86 | x86 | Architecture-neutral |
| x64 | x64 | x86 and x64 | Architecture-neutral |
| ARM64 | ARM64 | x86 and x64 compatibility packages | Architecture-neutral |

Both Visual C++ architectures are installed on 64-bit Windows because 32-bit and 64-bit applications require separate runtimes.

## Command-line options

Supplying explicit component options bypasses the interactive selector.

| Option | Values | Default | Purpose |
|---|---|---|---|
| `-Components` | `All`, `DotNet`, `VisualCpp`, `DirectX` | interactive | Select package groups |
| `-ExcludeComponents` | `DotNet`, `VisualCpp`, `DirectX` | none | Exclude package groups |
| `-DotNetChannels` | `All` or channels such as `8.0,10.0` | `All` | Select supported .NET channels |
| `-VisualCppVersions` | `All`, `2005`, `2008`, `2010`, `2012`, `2013`, `v14` | `All` | Select Visual C++ families |
| `-KeepDownloads` | switch | off | Retain metadata and package downloads |
| `-ReportPath` | folder or `.txt` path | none | Save a technical report |
| `-h`, `-Help`, `--help` | switch | off | Show help without elevation or network access |

Values are case-insensitive. Use `All` by itself; duplicate values and filters for disabled components are rejected.

Examples from a cloned repository:

```powershell
# Interactive installer
pwsh.exe -NoLogo -NoProfile -File .\Install.ps1

# Only .NET 8.0 and 10.0 SDKs
.\Install.ps1 -Components DotNet -DotNetChannels 8.0,10.0

# Only Visual C++ 2013 and the latest v14 family
.\Install.ps1 -Components VisualCpp -VisualCppVersions 2013,v14

# Complete offline help
.\Install.ps1 -Help
```

Windows PowerShell 5.1 fallback:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

## Requirements

- Windows on x86, x64, or ARM64
- Administrator Command Prompt
- Windows PowerShell 5.1 or PowerShell 7
- `curl.exe` in `PATH`
- Internet access to GitHub and the approved Microsoft hosts
- Sufficient disk space for the selected SDKs and runtimes

`-ExecutionPolicy Bypass` applies only to the launched PowerShell process and does not change the computer’s persistent execution policy.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | All selected packages completed successfully |
| `1` | Validation, download, verification, installation, or cleanup failed |
| `2` | Cancelled before package downloads |
| `3010` | Successful; Windows reports that a restart is required |

## Validation status

The project is checked with PowerShell parser validation, PSScriptAnalyzer 1.25.0 with Windows PowerShell 5.1 compatibility rules, fixture and regression tests, live GitHub source resolution, live Microsoft metadata resolution for x86, x64, and ARM64, and reviewed hashes for all fixed packages. A native Windows 11 smoke test exercised the selector, elevation, passive installers, cleanup, and successful completion on the preceding revision. The current discovery-collision fix has passed live source-plan and cleanup regressions; its final Windows confirmation is pending.

## Project notes

The separately maintained offline ZIP remains linked from the [original Reddit post](https://www.reddit.com/r/Batch/comments/1mwbttn/comment/p6iy6km/). It is not required by this GitHub version.

Microsoft owns and licenses the downloaded packages. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). This project is not affiliated with or endorsed by Microsoft.
