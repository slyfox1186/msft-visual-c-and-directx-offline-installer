# Microsoft Runtime Installer

A secure, architecture-aware Windows installer for supported Microsoft .NET SDKs, Microsoft Visual C++ redistributables, and the legacy DirectX End-User Runtimes (June 2010).

The project downloads packages directly from Microsoft at runtime. It does not store or redistribute Microsoft installers, and it does not require the maintainer to update hard-coded .NET version numbers whenever Microsoft publishes a stable SDK servicing release.

> The repository name is retained for continuity with the original offline project. This GitHub version is online-only. The separate Google Drive offline package remains available through the [original Reddit post](https://www.reddit.com/r/Batch/comments/1mwbttn/comment/p6iy6km/).

## Quick start

Open **Command Prompt** (`cmd.exe`) and paste this one-line curl command:

```bat
curl.exe -fsSL "https://raw.githubusercontent.com/slyfox1186/msft-visual-c-and-directx-offline-installer/main/Start.ps1" -o "%TEMP%\msri.ps1" && powershell.exe -ep bypass -f "%TEMP%\msri.ps1"
```

The command downloads the PowerShell launcher, which owns the detailed network, validation, retry, and cleanup policy and obtains one coherent source archive from this repository. `Install.ps1` then requests administrator access through Windows UAC, downloads the selected Microsoft packages, verifies them, installs them silently, and removes the temporary files. The downloaded launcher also removes itself when the run ends.

Review [Start.ps1](Start.ps1) and [Install.ps1](Install.ps1) before running them if you prefer to audit remote scripts first. [Bootstrap.ps1](Bootstrap.ps1) remains only as a compatibility entry point for the original published command.

## Choose what to install

The default installs all components. Add options after the launcher path in the quick-start command to narrow the plan.

Install only .NET SDK channels 8.0 and 10.0:

```bat
curl.exe -fsSL "https://raw.githubusercontent.com/slyfox1186/msft-visual-c-and-directx-offline-installer/main/Start.ps1" -o "%TEMP%\msri.ps1" && powershell.exe -ep bypass -f "%TEMP%\msri.ps1" -Components DotNet -DotNetChannels 8.0,10.0
```

Install only Visual C++ 2013 and the latest v14 family:

```bat
curl.exe -fsSL "https://raw.githubusercontent.com/slyfox1186/msft-visual-c-and-directx-offline-installer/main/Start.ps1" -o "%TEMP%\msri.ps1" && powershell.exe -ep bypass -f "%TEMP%\msri.ps1" -Components VisualCpp -VisualCppVersions 2013,v14
```

Install everything except DirectX and keep the verified downloads:

```bat
curl.exe -fsSL "https://raw.githubusercontent.com/slyfox1186/msft-visual-c-and-directx-offline-installer/main/Start.ps1" -o "%TEMP%\msri.ps1" && powershell.exe -ep bypass -f "%TEMP%\msri.ps1" -ExcludeComponents DirectX -KeepDownloads
```

Use `-h`, `-Help`, or `--help` to display the complete built-in menu without elevation or package downloads:

```bat
curl.exe -fsSL "https://raw.githubusercontent.com/slyfox1186/msft-visual-c-and-directx-offline-installer/main/Start.ps1" -o "%TEMP%\msri.ps1" && powershell.exe -ep bypass -f "%TEMP%\msri.ps1" --help
```

## Options

| Option | Values | Default | Behavior |
|---|---|---|---|
| `-Components` | `All`, `DotNet`, `VisualCpp`, `DirectX` | `All` | Enables one or more comma-delimited component groups. |
| `-ExcludeComponents` | `DotNet`, `VisualCpp`, `DirectX` | none | Removes groups after `-Components` is evaluated. |
| `-DotNetChannels` | `All` or stable channel numbers such as `8.0,10.0` | `All` | Installs only requested channels that Microsoft still supports. |
| `-VisualCppVersions` | `All`, `2005`, `2008`, `2010`, `2012`, `2013`, `v14` | `All` | Selects Visual C++ release families. |
| `-KeepDownloads` | switch | off | Retains verified Microsoft package files and prints their exact workspace path. |
| `-h`, `-Help`, `--help` | switch | off | Shows syntax, rules, examples, and exit codes without UAC or network activity. |

Values are case-insensitive. `All` must be used by itself, duplicate values are rejected, and fine-grained filters cannot target disabled components. Architecture cannot be overridden.

## Architecture behavior

| Windows architecture | .NET SDKs | Visual C++ | DirectX June 2010 |
|---|---|---|---|
| x86 (32-bit) | x86 | x86 only | Architecture-neutral package |
| x64 (64-bit) | x64 | x86 and x64 | Architecture-neutral package |

x64 Windows receives both Visual C++ architectures because 64-bit Windows can run both 32-bit and 64-bit applications. It receives only x64 .NET SDK installers because that is the native SDK architecture for the operating system.

## What gets installed

- Every currently supported stable .NET LTS or STS SDK channel reported as active or maintenance by Microsoft's release metadata. Preview and end-of-support channels are excluded automatically.
- Microsoft Visual C++ 2005 SP1, 2008 SP1, 2010 SP1, 2012 Update 4, 2013, and the latest supported v14 redistributable selected for the operating-system architecture.
- DirectX End-User Runtimes (June 2010), which supplies legacy side-by-side components used by older games and applications. It does not replace the version of DirectX built into Windows.

The v14 permanent Microsoft links update to Microsoft's latest supported Visual C++ v14 runtime. Older Visual C++ families and DirectX June 2010 are final legacy packages and therefore use fixed official Microsoft endpoints.

## Security and reliability controls

The installer:

- invokes the real `curl.exe`, not PowerShell's historical `curl` alias;
- requires HTTPS, limits redirects, uses timeouts and retries, and rejects non-approved effective hosts;
- parses Microsoft's .NET JSON as structured data and accepts only stable version, architecture, filename, URL, and SHA-512 formats;
- compares each .NET SDK file against Microsoft's published SHA-512 digest;
- requires valid Microsoft Corporation Authenticode signatures for Visual C++ and DirectX packages before execution;
- runs packages sequentially and reports the exact package and exit code on failure;
- accepts successful restart codes without silently losing the restart requirement; and
- creates a GUID-named workspace directly below `%TEMP%` and validates its exact shape before recursive cleanup.

The console dashboard shows each download, verification, installation, restart, and cleanup state. Output is ASCII-safe and uses standard Windows console colors so copied troubleshooting logs remain readable.

## Requirements

- Windows with Windows PowerShell 5.1 or later
- `curl.exe` available in `PATH`
- An internet connection that can reach GitHub and the approved Microsoft download hosts
- Administrator approval through Windows UAC
- Sufficient free space for the selected installers and installed SDKs

The `-ExecutionPolicy Bypass` option applies only to the newly launched Windows PowerShell process. It does not change the machine's persistent execution-policy configuration.

## Run from a cloned repository

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

Selective example:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Components DotNet,VisualCpp -DotNetChannels 10.0 -VisualCppVersions v14
```

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Every selected package completed successfully; no restart was reported. |
| `1` | Option validation, download, verification, installation, or required cleanup failed. |
| `3010` | Every selected package completed successfully and Windows reported that a restart is required. |

## Offline package

This repository intentionally contains no Microsoft EXE, CAB, DLL, MSI, or archive payloads. Users who specifically need the maintainer's separately packaged offline ZIP can find its Google Drive link in the [original Reddit post](https://www.reddit.com/r/Batch/comments/1mwbttn/comment/p6iy6km/).

## Verification status

Before publication, the installer was checked with a fixture/unit suite, PowerShell parser validation, PSScriptAnalyzer 1.25.0, live Microsoft metadata resolution, and live endpoint checks. Native Windows UAC, Authenticode, and installer execution could not be exercised from the Linux development host; that limitation is reported in the release notes until a native-Windows smoke test is completed.

## Third-party software

Microsoft owns and licenses the packages downloaded by this tool. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). This project is not affiliated with or endorsed by Microsoft.
