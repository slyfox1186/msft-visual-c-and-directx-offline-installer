#Requires -Version 5.1

<#
.SYNOPSIS
Downloads and runs the current Microsoft Runtime Installer source from GitHub.

.DESCRIPTION
This curl bootstrap downloads one coherent source archive, validates its GitHub
HTTPS origin, extracts it into a protected temporary workspace, forwards public
installer options, propagates the installer exit code, and removes bootstrap
source files.
#>

[CmdletBinding()]
param(
    [string]$Components = 'All',

    [AllowEmptyString()]
    [string]$ExcludeComponents = '',

    [string]$DotNetChannels = 'All',

    [string]$VisualCppVersions = 'All',

    [switch]$KeepDownloads,

    [Alias('h', 'Help')]
    [switch]$ShowHelp,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryArchiveUri = 'https://github.com/slyfox1186/msft-visual-c-and-directx-offline-installer/archive/refs/heads/main.zip'
$githubHostPattern = '^(?:github\.com|codeload\.github\.com)$'
$bootstrapLeafPattern = '^msft-runtime-bootstrap-[a-f0-9]{32}$'

function Write-BootstrapStatus {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'DOWNLOAD', 'OK', 'FAILED', 'CLEANUP')]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $color = [ConsoleColor]::Cyan
    if ($State -eq 'OK') { $color = [ConsoleColor]::Green }
    if ($State -eq 'FAILED') { $color = [ConsoleColor]::Red }
    if ($State -eq 'CLEANUP') { $color = [ConsoleColor]::DarkCyan }
    Write-Host ('[{0}] [{1,-8}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $State, $Message) -ForegroundColor $color
}

function Write-BootstrapHelp {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host '  MICROSOFT RUNTIME INSTALLER - CURL BOOTSTRAP' -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host 'USAGE' -ForegroundColor Cyan
    Write-Host '  Bootstrap.ps1 [options]'
    Write-Host ''
    Write-Host 'OPTIONS' -ForegroundColor Cyan
    Write-Host '  -Components <list>          All (default), DotNet, VisualCpp, DirectX'
    Write-Host '  -ExcludeComponents <list>   Remove component groups from the enabled set'
    Write-Host '  -DotNetChannels <list>      All, or supported channels such as 8.0,10.0'
    Write-Host '  -VisualCppVersions <list>   All, 2005, 2008, 2010, 2012, 2013, or v14'
    Write-Host '  -KeepDownloads              Keep verified Microsoft installers'
    Write-Host '  -h | -Help | --help         Show help without UAC or downloads'
    Write-Host ''
    Write-Host 'The bootstrap source archive is always temporary. KeepDownloads applies only'
    Write-Host 'to verified Microsoft package files downloaded by the installer.'
}

function Test-AllowedGitHubUri {
    param([Parameter(Mandatory = $true)][string]$Uri)

    try {
        $parsedUri = [uri]$Uri
        return $parsedUri.IsAbsoluteUri -and
            $parsedUri.Scheme -ceq 'https' -and
            $parsedUri.Port -eq 443 -and
            [string]::IsNullOrEmpty($parsedUri.UserInfo) -and
            $parsedUri.DnsSafeHost -match $githubHostPattern
    }
    catch {
        return $false
    }
}

function Test-SafeBootstrapWorkspace {
    param([Parameter(Mandatory = $true)][string]$WorkspacePath)

    try {
        $workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        return [string]::Equals((Split-Path -Parent $workspace), $temp, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $workspace) -match $bootstrapLeafPattern
    }
    catch {
        return $false
    }
}

function Assert-SafeOptionValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [switch]$AllowEmpty
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($AllowEmpty) { return }
        throw "$Name cannot be empty."
    }
    if ($Value -notmatch $Pattern) {
        throw "$Name contains an unsupported value or character: $Value"
    }
}

if ($null -ne $RemainingArguments -and $RemainingArguments.Count -gt 0) {
    if ($RemainingArguments.Count -eq 1 -and $RemainingArguments[0] -ceq '--help') {
        $ShowHelp = $true
    }
    else {
        Write-Host "Unknown argument(s): $($RemainingArguments -join ' ')" -ForegroundColor Red
        exit 1
    }
}

if ($ShowHelp) {
    Write-BootstrapHelp
    exit 0
}

$componentPattern = '(?i)^(?:All|DotNet|VisualCpp|DirectX)(?:\s*,\s*(?:All|DotNet|VisualCpp|DirectX))*$'
$dotNetPattern = '(?i)^(?:All|\d+\.\d+)(?:\s*,\s*(?:All|\d+\.\d+))*$'
$visualCppPattern = '(?i)^(?:All|2005|2008|2010|2012|2013|v14)(?:\s*,\s*(?:All|2005|2008|2010|2012|2013|v14))*$'
try {
    Assert-SafeOptionValue -Name 'Components' -Value $Components -Pattern $componentPattern
    Assert-SafeOptionValue -Name 'ExcludeComponents' -Value $ExcludeComponents -Pattern $componentPattern -AllowEmpty
    Assert-SafeOptionValue -Name 'DotNetChannels' -Value $DotNetChannels -Pattern $dotNetPattern
    Assert-SafeOptionValue -Name 'VisualCppVersions' -Value $VisualCppVersions -Pattern $visualCppPattern
}
catch {
    Write-BootstrapStatus -State FAILED -Message "Invalid bootstrap options: $($_.Exception.Message)"
    Write-Host 'Run Bootstrap.ps1 -Help for supported options.'
    exit 1
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This bootstrap supports Windows only. Help is available with -Help.'
}

$normalizedComponents = $Components -replace '\s', ''
$normalizedExclusions = $ExcludeComponents -replace '\s', ''
$normalizedDotNetChannels = $DotNetChannels -replace '\s', ''
$normalizedVisualCppVersions = $VisualCppVersions -replace '\s', ''
$workspacePath = Join-Path ([IO.Path]::GetTempPath()) ('msft-runtime-bootstrap-{0}' -f [guid]::NewGuid().ToString('N'))
$downloadedBootstrapPath = Join-Path ([IO.Path]::GetTempPath()) 'msft-runtime-bootstrap.ps1'
$shouldDeleteSelf = -not [string]::IsNullOrWhiteSpace($PSCommandPath) -and
    [string]::Equals([IO.Path]::GetFullPath($PSCommandPath), [IO.Path]::GetFullPath($downloadedBootstrapPath), [StringComparison]::OrdinalIgnoreCase)
$finalExitCode = 1

try {
    if (-not (Test-SafeBootstrapWorkspace -WorkspacePath $workspacePath)) {
        throw "Generated an unsafe bootstrap workspace: $workspacePath"
    }
    $null = New-Item -Path $workspacePath -ItemType Directory -ErrorAction Stop
    $archivePath = Join-Path $workspacePath 'source.zip'
    $extractionPath = Join-Path $workspacePath 'source'

    if (-not (Test-AllowedGitHubUri -Uri $repositoryArchiveUri)) {
        throw "Rejected bootstrap source URL: $repositoryArchiveUri"
    }
    $curlCommand = Get-Command -Name 'curl.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $curlArguments = @(
        '--fail', '--location', '--max-redirs', '10',
        '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2',
        '--retry', '4', '--retry-delay', '2', '--retry-connrefused',
        '--connect-timeout', '30', '--max-time', '600', '--progress-bar',
        '--show-error', '--output', $archivePath,
        '--write-out', '%{url_effective}', '--url', $repositoryArchiveUri
    )

    Write-BootstrapStatus -State DOWNLOAD -Message 'Downloading the current source archive from GitHub ...'
    $effectiveUriText = (& $curlCommand.Source @curlArguments | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-AllowedGitHubUri -Uri $effectiveUriText)) {
        throw "Rejected effective GitHub URL: $effectiveUriText"
    }

    $archive = Get-Item -LiteralPath $archivePath -ErrorAction Stop
    if ($archive.Length -le 4) { throw 'GitHub source archive is empty.' }
    $stream = [IO.File]::OpenRead($archivePath)
    try {
        if ($stream.ReadByte() -ne 0x50 -or $stream.ReadByte() -ne 0x4B) {
            throw 'GitHub source archive does not have a ZIP signature.'
        }
    }
    finally {
        $stream.Dispose()
    }
    Write-BootstrapStatus -State OK -Message ("Source archive downloaded ({0:N2} MB)." -f ($archive.Length / 1MB))

    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractionPath -Force -ErrorAction Stop
    $installScripts = @(Get-ChildItem -LiteralPath $extractionPath -Filter 'Install.ps1' -File -Recurse -ErrorAction Stop)
    if ($installScripts.Count -ne 1) {
        throw "Expected one Install.ps1 in the source archive; found $($installScripts.Count)."
    }
    $sourceRoot = $installScripts[0].Directory.FullName
    foreach ($requiredPath in @('src\ConsoleUI.psm1', 'src\RuntimeInstaller.psm1', 'config\packages.psd1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $requiredPath) -PathType Leaf)) {
            throw "Source archive is missing $requiredPath."
        }
    }
    Write-BootstrapStatus -State OK -Message 'Source archive structure validated.'

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $installScripts[0].FullName),
        '-Components', ('"{0}"' -f $normalizedComponents),
        '-DotNetChannels', ('"{0}"' -f $normalizedDotNetChannels),
        '-VisualCppVersions', ('"{0}"' -f $normalizedVisualCppVersions)
    )
    if (-not [string]::IsNullOrWhiteSpace($normalizedExclusions)) {
        $childArguments += @('-ExcludeComponents', ('"{0}"' -f $normalizedExclusions))
    }
    if ($KeepDownloads) { $childArguments += '-KeepDownloads' }

    Write-BootstrapStatus -State INFO -Message 'Starting the verified PowerShell installer ...'
    $childProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList $childArguments -Wait -PassThru -ErrorAction Stop
    if ($childProcess.ExitCode -notin @(0, 1, 3010)) {
        throw "Installer returned unexpected exit code $($childProcess.ExitCode)."
    }
    $finalExitCode = $childProcess.ExitCode
}
catch {
    Write-BootstrapStatus -State FAILED -Message $_.Exception.Message
    $finalExitCode = 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($workspacePath)) {
        try {
            if (-not (Test-SafeBootstrapWorkspace -WorkspacePath $workspacePath)) {
                throw "Refusing to remove unsafe bootstrap workspace: $workspacePath"
            }
            if (Test-Path -LiteralPath $workspacePath) {
                $workspaceItem = Get-Item -LiteralPath $workspacePath -Force -ErrorAction Stop
                if (($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing to remove a reparse-point bootstrap workspace: $workspacePath"
                }
                Remove-Item -LiteralPath $workspacePath -Recurse -Force -ErrorAction Stop
                Write-BootstrapStatus -State CLEANUP -Message 'Bootstrap source files removed.'
            }
        }
        catch {
            Write-BootstrapStatus -State FAILED -Message "Bootstrap cleanup failed: $($_.Exception.Message)"
            $finalExitCode = 1
        }
    }

    if ($shouldDeleteSelf) {
        try {
            Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction Stop
        }
        catch {
            Write-BootstrapStatus -State FAILED -Message "Downloaded bootstrap cleanup failed: $($_.Exception.Message)"
            $finalExitCode = 1
        }
    }
}

exit $finalExitCode
