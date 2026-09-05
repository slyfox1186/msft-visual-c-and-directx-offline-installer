#Requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$Components = 'All',
    [AllowEmptyString()][string[]]$ExcludeComponents = '',
    [string[]]$DotNetChannels = 'All',
    [string[]]$VisualCppVersions = 'All',
    [switch]$KeepDownloads,
    [AllowEmptyString()][string]$ReportPath = '',
    [Alias('h', 'Help')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments
)

# Keep execution inside one function for previously published stdin launchers.
function Invoke-MicrosoftRuntimeLauncher {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$BoundParameters)
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $Options = @{}
    foreach ($name in @('Components', 'ExcludeComponents', 'DotNetChannels', 'VisualCppVersions', 'KeepDownloads', 'ReportPath', 'ShowHelp', 'RemainingArguments')) {
        if ($BoundParameters.ContainsKey($name)) { $Options[$name] = $BoundParameters[$name] }
    }

    function Write-LauncherStatus {
        param([ValidateSet('INFO', 'DOWNLOAD', 'OK', 'FAILED', 'CLEANUP')][string]$State, [string]$Message)
        $prefix = '[{0}] ' -f $State.PadLeft([int][math]::Floor((8 + $State.Length) / 2)).PadRight(8)
        $text = ($Message -replace '[^\x20-\x7e]', ' ').Trim()
        do {
            $length = [math]::Min(78 - $prefix.Length, $text.Length)
            Write-Host ($prefix + $text.Substring(0, $length))
            $text = $text.Substring($length)
            $prefix = ' ' * $prefix.Length
        } while ($text.Length)
    }

    function Test-AllowedGitHubUri {
        param([string]$Uri, [string]$ExpectedHost, [string]$ExpectedAbsolutePath)
        try {
            $parsed = [uri]$Uri
            return $parsed.IsAbsoluteUri -and $parsed.Scheme -ceq 'https' -and $parsed.Port -eq 443 -and
                -not $parsed.UserInfo -and $parsed.DnsSafeHost -ieq $ExpectedHost -and
                $parsed.AbsolutePath -ceq $ExpectedAbsolutePath -and -not $parsed.Query -and -not $parsed.Fragment
        } catch { return $false }
    }

    function Test-SafeLauncherWorkspace {
        param([string]$WorkspacePath)
        $full = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd([IO.Path]::DirectorySeparatorChar)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
        return (Split-Path $full -Parent) -ieq $temp -and (Split-Path $full -Leaf) -cmatch '\Amsft-runtime-launcher-[a-f0-9]{32}\z'
    }

    function Invoke-GitHubSourceDownload {
        param([string]$Uri, [string]$DestinationPath, [string]$WorkspacePath)
        $parsed = [uri]$Uri
        if ($parsed.DnsSafeHost -notin @('api.github.com', 'raw.githubusercontent.com') -or
            -not (Test-AllowedGitHubUri $Uri $parsed.DnsSafeHost $parsed.AbsolutePath)) {
            throw 'Rejected GitHub source URL.'
        }
        $destination = [IO.Path]::GetFullPath($DestinationPath)
        $prefix = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $destination.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $destination)) {
            throw 'Source destination must be a new file inside the launcher workspace.'
        }
        $arguments = @('--fail', '--location', '--max-redirs', '10', '--proto', '=https', '--proto-redir', '=https',
            '--tlsv1.2', '--retry', '4', '--retry-delay', '2', '--retry-connrefused', '--connect-timeout', '30',
            '--max-time', '120', '--silent', '--show-error', '--output', $destination, '--write-out', '%{url_effective}', '--url', $Uri)
        if ($parsed.DnsSafeHost -eq 'api.github.com') {
            $arguments += @('--header', 'Accept: application/vnd.github+json', '--header', 'X-GitHub-Api-Version: 2026-03-10')
        }
        try {
            $effective = (& $curlExecutable @arguments | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) { throw "GitHub download failed: curl exit $LASTEXITCODE." }
            if (-not (Test-AllowedGitHubUri $effective $parsed.DnsSafeHost $parsed.AbsolutePath)) { throw 'Rejected effective GitHub source URL.' }
            $file = Get-Item -LiteralPath $destination -Force
            if ($file.PSIsContainer -or $file.Length -le 0 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'GitHub source must be a nonempty regular file.'
            }
            return $file
        } catch {
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            throw
        }
    }

    $workspace = Join-Path ([IO.Path]::GetTempPath()) ('msft-runtime-launcher-' + [guid]::NewGuid().ToString('N'))
    $ownsWorkspace = $false
    $exitCode = 1
    try {
        if ($Options.ContainsKey('RemainingArguments')) {
            $remaining = @($Options.RemainingArguments)
            if ($remaining.Count -ne 1 -or $remaining[0] -cne '--help') { throw "Unknown argument(s): $($remaining -join ' ')" }
            $Options.ShowHelp = $true
            $Options.Remove('RemainingArguments')
        }
        if ($Options.ContainsKey('ShowHelp') -and $Options.ShowHelp) {
            Write-Host @'
Microsoft Runtime Installer - Start.ps1 [options]

-Components         All, DotNet, VisualCpp, DirectX
-ExcludeComponents  Groups to remove
-DotNetChannels     All or supported channels, e.g. 8.0,10.0
-VisualCppVersions  All, 2005, 2008, 2010, 2012, 2013, v14
-KeepDownloads      Keep Microsoft downloads, not launcher source files
-ReportPath         Save a technical .txt report
-h, -Help, --help   Show help without UAC or network access

No package options opens the menu. Explicit options run unattended.
.NET uses current supported channels; v14 uses the latest supported release.
Older Visual C++ and DirectX are final releases. Sources resolve at run time.
PowerShell 7 is preferred, with Windows PowerShell 5.1 as the fallback.
Exit codes: 0 success, 1 failure, 2 cancelled, 3010 restart required.
'@
            $exitCode = 0
        }
        else {
            if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This launcher supports Windows only. Help is available with -Help.' }
            # Prefer the OS downloader so a writable PATH cannot shadow System32.
            $curlExecutable = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (-not (Test-Path -LiteralPath $curlExecutable -PathType Leaf)) {
                $curlExecutable = (Get-Command curl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
            }
            if (-not (Test-SafeLauncherWorkspace $workspace)) { throw 'Unsafe launcher workspace.' }
            $null = New-Item -Path $workspace -ItemType Directory
            $ownsWorkspace = $true
            $repository = 'slyfox1186/msft-visual-c-and-directx-offline-installer'
            Write-LauncherStatus DOWNLOAD 'Resolving one GitHub commit and fetching installer source ...'
            $refFile = Invoke-GitHubSourceDownload "https://api.github.com/repos/$repository/git/ref/heads/main" (Join-Path $workspace 'ref.json') $workspace
            $revision = Get-Content -LiteralPath $refFile.FullName -Raw | ConvertFrom-Json
            if ($revision.ref -cne 'refs/heads/main' -or $revision.object.type -cne 'commit' -or
                [string]$revision.object.sha -cnotmatch '\A[0-9a-f]{40}\z') { throw 'Invalid GitHub main commit metadata.' }
            $sha = [string]$revision.object.sha
            foreach ($relative in @('Install.ps1', 'src/ConsoleUI.psm1', 'src/RuntimeInstaller.psm1', 'config/packages.psd1')) {
                $destination = Join-Path $workspace $relative
                $null = New-Item -Path (Split-Path $destination -Parent) -ItemType Directory -Force
                $file = Invoke-GitHubSourceDownload "https://raw.githubusercontent.com/$repository/$sha/$relative" $destination $workspace
                $parseErrors = $null
                [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
                if ($parseErrors.Count) { throw "Downloaded source failed syntax validation: $relative" }
            }
            # Shared process helpers are trusted only after all four source files validate.
            Import-Module (Join-Path $workspace 'src/RuntimeInstaller.psm1') -Force
            $Options.SourceRevision = $sha
            $arguments = Get-InstallerChildArgument (Join-Path $workspace 'Install.ps1') $Options
            $start = @{ FilePath = Get-InstallerPowerShell; ArgumentList = $arguments; Wait = $true; PassThru = $true }
            $explicitSelection = @($Options.Keys | Where-Object { $_ -in @('Components', 'ExcludeComponents', 'DotNetChannels', 'VisualCppVersions') }).Count -gt 0
            if ($explicitSelection -or -not [Console]::IsInputRedirected) { $start.NoNewWindow = $true }
            else { $start.WindowStyle = 'Maximized' }
            Write-LauncherStatus OK "Starting validated revision $($sha.Substring(0, 12)) ..."
            $exitCode = (Start-Process @start).ExitCode
            if ($exitCode -notin @(0, 1, 2, 3010)) { throw "Unexpected installer exit code: $exitCode" }
        }
    }
    catch {
        Write-LauncherStatus FAILED $_.Exception.Message
        $exitCode = 1
    }
    finally {
        try {
            if ($ownsWorkspace) {
                if (-not (Test-SafeLauncherWorkspace $workspace)) { throw 'Refusing unsafe launcher cleanup.' }
                $item = Get-Item -LiteralPath $workspace -Force
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing reparse-point launcher cleanup.' }
                Remove-Item -LiteralPath $workspace -Recurse -Force
                Write-LauncherStatus CLEANUP 'Launcher source files removed.'
            }
            $legacyPath = Join-Path ([IO.Path]::GetTempPath()) 'msri.ps1'
            if ($PSCommandPath -and [IO.Path]::GetFullPath($PSCommandPath) -ieq $legacyPath) {
                Remove-Item -LiteralPath $PSCommandPath -Force
            }
        } catch {
            Write-LauncherStatus FAILED "Launcher cleanup failed: $($_.Exception.Message)"
            $exitCode = 1
        }
    }
    exit $exitCode
}

Invoke-MicrosoftRuntimeLauncher -BoundParameters $PSBoundParameters
