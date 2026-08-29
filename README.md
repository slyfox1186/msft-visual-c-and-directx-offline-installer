# Microsoft Runtime Installer

A secure, architecture-aware Windows installer for supported Microsoft .NET SDKs, Microsoft Visual C++ redistributables, and the legacy DirectX End-User Runtimes (June 2010).

The project downloads packages directly from Microsoft at runtime. It resolves every selected installer from official Microsoft metadata, dedicated Microsoft aliases, documentation, or Download Center pages before any package runs. For rolling packages, it resolves the latest stable SDK version for every selected, currently supported .NET channel and the latest supported Visual C++ v14 release. Visual C++ 2005-2013 and DirectX June 2010 are final fixed legacy releases, but even their payload URLs are resolved at run time rather than stored in the repository. The repository stores no Microsoft installers or installer URLs and does not pin rolling package versions that would become stale.

> The repository name is retained for continuity with the original offline project. This GitHub version is online-only. The separate Google Drive offline package remains available through the [original Reddit post](https://www.reddit.com/r/Batch/comments/1mwbttn/comment/p6iy6km/).

## Quick start

1. Open the Windows **Start** menu and search for **Command Prompt**.
2. Select **Run as administrator**, then approve the Windows UAC prompt.
3. Paste this one-line command into the Administrator Command Prompt and press **Enter**:

```bat
start "Microsoft Runtime Installer" /max powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$msriSource=@(& curl.exe -fsS 'https://raw.githubusercontent.com/slyfox1186/msft-visual-c-and-directx-offline-installer/main/Start.ps1');if($LASTEXITCODE -ne 0 -or $msriSource.Count -eq 0){exit 1};try{$msriScript=[ScriptBlock]::Create($msriSource -join [Environment]::NewLine)}catch{exit 1};& $msriScript" && exit
```

The Administrator Command Prompt starts one independent, maximized PowerShell window and then closes immediately. The PowerShell window inherits administrator access and owns the complete run: it displays the interactive selector with every component initially enabled, downloads and validates the supporting source, waits for installation, removes temporary source files, and closes when finished. After successful source validation, the selector clears the bootstrap progress from the display; bootstrap errors remain visible if validation fails. Toggle packages or change optional settings, then press **Enter** when ready. Downloads, verification, and installation then run automatically. Supported Microsoft progress windows remain visible, but they require no clicks or other input. The scripts suppress automatic restarts and report when a manual restart is needed.

The command does not create a bootstrap script in `%TEMP%`. The independent PowerShell process uses `curl.exe` to collect the complete `Start.ps1` response, rejects curl failures and empty responses, then parses the source as one script before invoking it. A malformed response fails closed with exit code `1` and cannot execute partially. This avoids the statement-at-a-time behavior of `-Command -` with multi-line advanced scripts. The launcher prefers `pwsh.exe` from `PATH` when PowerShell 7 is installed and otherwise continues with Windows PowerShell 5.1. Its validated child stays in the same keyboard-connected PowerShell window.

Run the command from an **Administrator Command Prompt**. The installer retains its own elevation check as a safety fallback, but starting elevated keeps the complete run in the single independent, maximized PowerShell window opened by the command.

No repository ZIP is downloaded or extracted. The launcher resolves `main` to one validated Git commit, then uses `curl.exe` to download `Install.ps1`, both PowerShell modules, and the package configuration individually from that immutable revision. It validates each GitHub URL, downloaded file, and PowerShell syntax before execution, then removes those temporary source files when the installer exits.

Review [Start.ps1](Start.ps1) and [Install.ps1](Install.ps1) before running them if you prefer to audit remote scripts first. [Bootstrap.ps1](Bootstrap.ps1) remains only as a compatibility entry point for the original published command.

## Interactive package selection

The selector uses one full-screen view with each package description directly below its action. Text labels communicate every state without relying on color: package rows show `ON` or `OFF`, settings are written as actions, every setting has a `Current selection` line, and unavailable filters identify the package that must be enabled. Package descriptions distinguish dynamically resolved stable releases from final fixed legacy releases.

Successful bootstrap progress is cleared immediately before the first selector render. Every choice then clears and redraws that same screen, preserving a short confirmation or error message without stacking duplicate menus. Pressing **Enter** clears the selector before UAC or installation output begins. Download and validation failures are not cleared.

The default menu provides these controls:

- `1`, `2`, and `3` toggle .NET SDKs, Visual C++ runtimes, and DirectX;
- `4` selects specific supported .NET SDK channels;
- `5` selects specific Visual C++ release families;
- `A` restores the complete package selection;
- `K` keeps the installer workspace instead of deleting it;
- **Enter** starts the confirmed plan; and
- `Q` cancels before elevation or downloads.

At least one package group must remain selected. Only one current selector is visible before UAC, and installation is unattended after confirmation.

## Advanced noninteractive use

Explicit selection switches bypass the menu. This is intended for automation or for users running a reviewed clone of the repository.

Install only .NET SDK channels 8.0 and 10.0 from a clone:

```powershell
.\Install.ps1 -Components DotNet -DotNetChannels 8.0,10.0
```

Install only Visual C++ 2013 and the latest v14 family from a clone:

```powershell
.\Install.ps1 -Components VisualCpp -VisualCppVersions 2013,v14
```

The complete help menu remains available without elevation or downloads:

```powershell
.\Install.ps1 -Help
```

## Options

| Option | Values | Default | Behavior |
|---|---|---|---|
| `-Components` | `All`, `DotNet`, `VisualCpp`, `DirectX` | interactive | Enables one or more comma-delimited component groups and bypasses the selector. |
| `-ExcludeComponents` | `DotNet`, `VisualCpp`, `DirectX` | none | Removes groups after `-Components` is evaluated. |
| `-DotNetChannels` | `All` or stable channel numbers such as `8.0,10.0` | `All` | Installs only requested channels that Microsoft still supports. |
| `-VisualCppVersions` | `All`, `2005`, `2008`, `2010`, `2012`, `2013`, `v14` | `All` | Selects Visual C++ release families. |
| `-KeepDownloads` | switch | off | Retains the installer workspace, including downloaded metadata and packages, and prints its path. |
| `-ReportPath` | folder or `.txt` path | none | Writes a timestamped technical report to a folder, or writes the requested `.txt` filename. Interactive runs can choose this from the final screen. |
| `-h`, `-Help`, `--help` | switch | off | Shows syntax, rules, examples, and exit codes without UAC or network activity. |

Values are case-insensitive. `All` must be used by itself, duplicate values are rejected, and fine-grained filters cannot target disabled components. Architecture cannot be overridden.

## Architecture behavior

| Windows architecture | .NET SDKs | Visual C++ | DirectX June 2010 |
|---|---|---|---|
| x86 (32-bit) | x86 | x86 only | Architecture-neutral package |
| x64 (64-bit) | x64 | x86 and x64 | Architecture-neutral package |
| ARM64 | ARM64 | x86 and x64-compatible packages | Architecture-neutral package |

x64 Windows receives both Visual C++ architectures because 64-bit Windows can run both 32-bit and 64-bit applications. ARM64 Windows receives native ARM64 .NET SDKs plus the x86 and x64 Visual C++ compatibility packages needed by emulated applications. The current v14 x64 redistributable also carries ARM64 binaries. Each system receives only its native .NET SDK architecture.

## What gets installed

- Every currently supported stable .NET LTS or STS SDK channel reported as active or maintenance by Microsoft's release metadata. Preview and end-of-support channels are excluded automatically.
- Microsoft Visual C++ 2005 SP1, 2008 SP1, 2010 SP1, 2012 Update 4, 2013, and the latest supported v14 redistributable selected for the operating-system architecture.
- DirectX End-User Runtimes (June 2010), which supplies legacy side-by-side components used by older games and applications. It does not replace the version of DirectX built into Windows.

## How versions stay current

- **.NET SDKs are dynamic.** Every run uses Microsoft's release index to keep only supported LTS or STS channels in active or maintenance support. It checks each channel's dedicated `latest.version` endpoint and uses that version when the same SDK appears in Microsoft's SHA-512-bearing release metadata. If Microsoft's CDNs are briefly out of sync, it uses the newest stable SDK that can be verified by the release metadata instead of downloading an unverifiable file. Preview strings are rejected.
- **Visual C++ v14 is dynamic.** Every run uses Microsoft's dedicated latest-supported x86 and x64 aliases. After Microsoft digital-signature verification, the installer reads the executable's file version and rejects an unexpected shape, the retired `14.0` line, or a downgrade below the reviewed security floor.
- **Visual C++ 2005-2013 are final releases with dynamic source resolution.** Visual C++ 2013 uses Microsoft's permanent architecture aliases. The 2008-2012 resolver isolates the requested release-family section and architecture row in Microsoft's current documentation. Visual C++ 2005 is resolved by exact filename from its official Download Center page because Microsoft does not publish a payload row for that family in the documentation.
- **DirectX June 2010 is fixed with dynamic source resolution.** The resolver extracts exactly one matching package URL from the official Download Center page at run time. The release itself is fixed; the source URL is not stored in the repository.

The complete selected source plan must resolve successfully before any package executable runs. Missing, ambiguous, non-HTTPS, unexpected-host, wrong-architecture, or malformed catalog results fail closed. Fixed Visual C++ and DirectX packages must also match reviewed SHA-256 values, so a changed catalog page or re-hosted file cannot silently change the bytes that execute. The terminal identifies each policy before installation and prints concrete .NET and downloaded Visual C++ file versions. This distinction prevents “latest” from being used misleadingly for legacy products that no longer have rolling releases.

## Security and reliability controls

The installer:

- invokes the real `curl.exe`, not PowerShell's historical `curl` alias;
- resolves one GitHub commit, validates its 40-character SHA, and downloads the fixed source manifest as individual raw files rather than an archive;
- requires HTTPS, limits redirects, uses timeouts and retries, and rejects non-approved effective hosts;
- keeps discovery-page hosts separate from executable-download hosts, limits catalog document size, and requires exactly one regex-extracted payload candidate for the requested family, architecture, and filename;
- parses Microsoft's .NET JSON as structured data, checks the dedicated stable-version endpoint, and accepts only stable version, architecture, filename, URL, and SHA-512 formats;
- compares each .NET SDK file against Microsoft's published SHA-512 digest;
- compares every fixed Visual C++ and DirectX download against its reviewed SHA-256 digest before checking its digital signature;
- requires valid Microsoft Corporation Authenticode signatures for Visual C++ and DirectX packages before execution, reads Visual C++ PE version metadata only after signature validation, and enforces a reviewed minimum version for rolling v14 packages;
- runs packages sequentially, displays supported passive progress UI, and reports the exact package and exit code on failure;
- accepts successful restart codes without silently losing the restart requirement;
- suppresses automatic package restarts so the user remains in control; and
- creates a GUID-named workspace directly below `%TEMP%` and validates its exact shape before recursive cleanup.

The console dashboard shows each resolution, download, verification, installation, restart, and cleanup state. It adapts from a compact 78-column fallback up to a readable 110-column maximized layout. Centered fixed-width badges, neutral message text, consistent columns, plain-language results, and per-package progress make the current action easy to scan without turning the log into a wall of color. The full-screen selector uses vertically grouped descriptions, explicit text states, visible current settings, redraw-in-place feedback, and a highlighted primary action. Output is ASCII-safe and uses standard Windows console colors only as reinforcement, so the interface and copied troubleshooting logs remain understandable without color.

After cleanup, an interactive run replaces the progress log with a concise final result screen. It states whether every selected package completed, whether a restart is required, whether temporary downloads were removed, and the first recorded failure when attention is needed. Press `R` to save a developer/IT technical report before exiting, or press any other key to close. The report defaults to a timestamped `.txt` file under `%USERPROFILE%`; the prompt accepts either another folder or a complete `.txt` path. Reports include run identity, source revision, system and architecture details, the requested and resolved package plan, trust controls, cleanup results, an event timeline, package exit codes, and failure guidance. User-profile and temp paths are normalized in report text, and credentials, environment dumps, and package contents are excluded.

## Requirements

- Windows PowerShell 5.1 (built in) or PowerShell 7 (`pwsh.exe` in `PATH`); PowerShell 7 is preferred automatically
- `curl.exe` available in `PATH`
- An internet connection that can reach GitHub and the approved Microsoft download hosts
- Administrator Command Prompt (`cmd.exe` opened with **Run as administrator**)
- Sufficient free space for the selected installers and installed SDKs

The `-ExecutionPolicy Bypass` option applies only to the newly launched PowerShell process. It does not change the machine's persistent execution-policy configuration.

## Run from a cloned repository

PowerShell 7, when installed:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Install.ps1
```

Windows PowerShell 5.1 fallback:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

Selective example (run from either host):

```powershell
.\Install.ps1 -Components DotNet,VisualCpp -DotNetChannels 10.0 -VisualCppVersions v14
```

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Every selected package completed successfully; no restart was reported. |
| `1` | Option validation, download, verification, installation, or required cleanup failed. |
| `2` | The interactive selector was cancelled before elevation or package downloads. |
| `3010` | Every selected package completed successfully and Windows reported that a restart is required. |

## Offline package

This repository intentionally contains no Microsoft EXE, CAB, DLL, MSI, or archive payloads. Users who specifically need the maintainer's separately packaged offline ZIP can find its Google Drive link in the [original Reddit post](https://www.reddit.com/r/Batch/comments/1mwbttn/comment/p6iy6km/).

## Verification status

Before publication, the installer was checked with a fixture/unit suite, an explicit no-archive regression, PowerShell parser validation, PSScriptAnalyzer 1.25.0 (including Windows PowerShell 5.1 syntax, command, and type compatibility rules), live commit-pinned GitHub source resolution, live Microsoft metadata resolution for x86, x64, and ARM64, and live checks of every configured endpoint. A fresh live audit also downloaded all 11 fixed legacy packages and confirmed every reviewed SHA-256. On 2026-08-29, both Microsoft v14 aliases served file version `14.51.36247.0`, which is the current reviewed downgrade floor. A native Windows 11 smoke test subsequently exercised the selector, elevation, passive installers, cleanup, and a successful completion on the preceding revision. The current discovery-collision correction has passed live source-plan and cleanup regressions; its final native Windows confirmation is pending.

## Third-party software

Microsoft owns and licenses the packages downloaded by this tool. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). This project is not affiliated with or endorsed by Microsoft.
