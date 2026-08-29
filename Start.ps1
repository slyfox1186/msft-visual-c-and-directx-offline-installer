#Requires -Version 5.1

<#
.SYNOPSIS
Downloads and runs the current Microsoft Runtime Installer source from GitHub.

.DESCRIPTION
Designed for curl-to-PowerShell streaming, this launcher downloads one coherent
source archive, validates its GitHub HTTPS origin, extracts it into a protected
temporary workspace, opens the interactive selector when no package options
were supplied, propagates the installer exit code, and removes source files.
#>

[CmdletBinding()]
param(
    [string[]]$Components = 'All',

    [AllowEmptyString()]
    [string[]]$ExcludeComponents = '',

    [string[]]$DotNetChannels = 'All',

    [string[]]$VisualCppVersions = 'All',

    [switch]$KeepDownloads,

    [Alias('h', 'Help')]
    [switch]$ShowHelp,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

function Invoke-MicrosoftRuntimeLauncher {
    [CmdletBinding()]
    param(
        [string[]]$Components = 'All',

        [AllowEmptyString()]
        [string[]]$ExcludeComponents = '',

        [string[]]$DotNetChannels = 'All',

        [string[]]$VisualCppVersions = 'All',

        [switch]$KeepDownloads,

        [switch]$ShowHelp,

        [string[]]$RemainingArguments,

        [Parameter(Mandatory = $true)]
        [Collections.IDictionary]$OriginalBoundParameters
    )

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$selectionOptionsWereBound = @(
    @('Components', 'ExcludeComponents', 'DotNetChannels', 'VisualCppVersions') |
        Where-Object { $OriginalBoundParameters.ContainsKey($_) }
)

$repositoryArchiveUri = 'https://github.com/slyfox1186/msft-visual-c-and-directx-offline-installer/archive/refs/heads/main.zip'
$githubHostPattern = '\A(?:github\.com|codeload\.github\.com)\z'
$launcherLeafPattern = '\Amsft-runtime-launcher-[a-f0-9]{32}\z'
$launcherWasStreamed = [string]::IsNullOrWhiteSpace($PSCommandPath)
$downloadedLauncherPath = Join-Path ([IO.Path]::GetTempPath()) 'msri.ps1'
$shouldDeleteSelf = -not [string]::IsNullOrWhiteSpace($PSCommandPath) -and
    [string]::Equals([IO.Path]::GetFullPath($PSCommandPath), [IO.Path]::GetFullPath($downloadedLauncherPath), [StringComparison]::OrdinalIgnoreCase)

function Write-LauncherStatus {
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
    $timestamp = [datetime]::Now.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    Write-Host ('[{0}] [{1,-8}] {2}' -f $timestamp, $State, $Message) -ForegroundColor $color
}

function Write-LauncherHelp {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host '  MICROSOFT RUNTIME INSTALLER - CURL LAUNCHER' -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host 'USAGE' -ForegroundColor Cyan
    Write-Host '  Start.ps1 [options]'
    Write-Host ''
    Write-Host 'OPTIONS' -ForegroundColor Cyan
    Write-Host '  -Components <list>          All (default), DotNet, VisualCpp, DirectX'
    Write-Host '  -ExcludeComponents <list>   Remove component groups from the enabled set'
    Write-Host '  -DotNetChannels <list>      All, or supported channels such as 8.0,10.0'
    Write-Host '  -VisualCppVersions <list>   All, 2005, 2008, 2010, 2012, 2013, or v14'
    Write-Host '  -KeepDownloads              Keep the Microsoft installer workspace'
    Write-Host '  -h | -Help | --help         Show help without UAC or downloads'
    Write-Host ''
    Write-Host 'With no selection options, an interactive package menu opens.'
    Write-Host 'Explicit package options bypass the menu for automation.'
    Write-Host 'The launcher source archive is always temporary. KeepDownloads applies only'
    Write-Host 'to the installer workspace, including downloaded metadata and packages.'
    Write-Host 'PowerShell 7 is preferred when pwsh.exe is in PATH; 5.1 is the fallback.'
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

function Test-SafeLauncherWorkspace {
    param([Parameter(Mandatory = $true)][string]$WorkspacePath)

    try {
        $workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        return [string]::Equals((Split-Path -Parent $workspace), $temp, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $workspace) -match $launcherLeafPattern
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

function ConvertTo-DotNetChannelText {
    param([Parameter(Mandatory = $true)][string[]]$Value)

    $tokens = foreach ($item in $Value) {
        foreach ($token in $item.Split(',')) {
            if ($token -match '\A([ \t]*)(\d+)([ \t]*)\z') {
                '{0}{1}.0{2}' -f $matches[1], $matches[2], $matches[3]
            }
            else {
                $token
            }
        }
    }
    return $tokens -join ','
}

function Get-PreferredPowerShellExecutable {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $pwshCommand = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $pwshCommand) {
        return $pwshCommand.Source
    }

    $windowsPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf)) {
        throw 'Neither pwsh.exe nor Windows PowerShell 5.1 could be found.'
    }
    return $windowsPowerShellPath
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
    Write-LauncherHelp
    if ($shouldDeleteSelf) {
        try {
            Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction Stop
        }
        catch {
            Write-LauncherStatus -State FAILED -Message "Downloaded launcher cleanup failed: $($_.Exception.Message)"
            exit 1
        }
    }
    exit 0
}

$componentText = @($Components) -join ','
$excludedComponentText = @($ExcludeComponents) -join ','
$dotNetChannelText = ConvertTo-DotNetChannelText -Value $DotNetChannels
$visualCppVersionText = @($VisualCppVersions) -join ','

$componentPattern = '(?i)\A(?:All|DotNet|VisualCpp|DirectX)(?:[ \t]*,[ \t]*(?:All|DotNet|VisualCpp|DirectX))*\z'
$dotNetPattern = '(?i)\A(?:All|\d+\.\d+)(?:[ \t]*,[ \t]*(?:All|\d+\.\d+))*\z'
$visualCppPattern = '(?i)\A(?:All|2005|2008|2010|2012|2013|v14)(?:[ \t]*,[ \t]*(?:All|2005|2008|2010|2012|2013|v14))*\z'
try {
    Assert-SafeOptionValue -Name 'Components' -Value $componentText -Pattern $componentPattern
    Assert-SafeOptionValue -Name 'ExcludeComponents' -Value $excludedComponentText -Pattern $componentPattern -AllowEmpty
    Assert-SafeOptionValue -Name 'DotNetChannels' -Value $dotNetChannelText -Pattern $dotNetPattern
    Assert-SafeOptionValue -Name 'VisualCppVersions' -Value $visualCppVersionText -Pattern $visualCppPattern
}
catch {
    Write-LauncherStatus -State FAILED -Message "Invalid launcher options: $($_.Exception.Message)"
    Write-Host 'Run Start.ps1 -Help for supported options.'
    exit 1
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This launcher supports Windows only. Help is available with -Help.'
}

$normalizedComponents = $componentText -replace '\s', ''
$normalizedExclusions = $excludedComponentText -replace '\s', ''
$normalizedDotNetChannels = $dotNetChannelText -replace '\s', ''
$normalizedVisualCppVersions = $visualCppVersionText -replace '\s', ''
$workspacePath = Join-Path ([IO.Path]::GetTempPath()) ('msft-runtime-launcher-{0}' -f [guid]::NewGuid().ToString('N'))
$finalExitCode = 1

try {
    if (-not (Test-SafeLauncherWorkspace -WorkspacePath $workspacePath)) {
        throw "Generated an unsafe launcher workspace: $workspacePath"
    }
    $null = New-Item -Path $workspacePath -ItemType Directory -ErrorAction Stop
    $archivePath = Join-Path $workspacePath 'source.zip'
    $extractionPath = Join-Path $workspacePath 'source'

    if (-not (Test-AllowedGitHubUri -Uri $repositoryArchiveUri)) {
        throw "Rejected launcher source URL: $repositoryArchiveUri"
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

    Write-LauncherStatus -State DOWNLOAD -Message 'Downloading the current source archive from GitHub ...'
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
    Write-LauncherStatus -State OK -Message ("Source archive downloaded ({0:N2} MB)." -f ($archive.Length / 1MB))

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
    Write-LauncherStatus -State OK -Message 'Source archive structure validated.'

    $powershellExecutable = Get-PreferredPowerShellExecutable
    $childArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $installScripts[0].FullName)
    )
    if ($selectionOptionsWereBound.Count -gt 0) {
        $childArguments += @(
            '-Components', ('"{0}"' -f $normalizedComponents),
            '-DotNetChannels', ('"{0}"' -f $normalizedDotNetChannels),
            '-VisualCppVersions', ('"{0}"' -f $normalizedVisualCppVersions)
        )
        if (-not [string]::IsNullOrWhiteSpace($normalizedExclusions)) {
            $childArguments += @('-ExcludeComponents', ('"{0}"' -f $normalizedExclusions))
        }
    }
    if ($KeepDownloads) { $childArguments += '-KeepDownloads' }

    $powerShellHostName = [IO.Path]::GetFileName($powershellExecutable)
    Write-LauncherStatus -State INFO -Message "Starting the validated source with $powerShellHostName ..."
    $startParameters = @{
        FilePath     = $powershellExecutable
        ArgumentList = $childArguments
        Wait         = $true
        PassThru     = $true
        ErrorAction  = 'Stop'
    }
    if ($selectionOptionsWereBound.Count -gt 0 -or -not $launcherWasStreamed) {
        $startParameters.NoNewWindow = $true
    }
    $childProcess = Start-Process @startParameters
    if ($childProcess.ExitCode -notin @(0, 1, 2, 3010)) {
        throw "Installer returned unexpected exit code $($childProcess.ExitCode)."
    }
    $finalExitCode = $childProcess.ExitCode
    if ($finalExitCode -eq 0) {
        Write-LauncherStatus -State OK -Message 'Installer completed successfully.'
    }
    elseif ($finalExitCode -eq 2) {
        Write-LauncherStatus -State INFO -Message 'Installation was cancelled before any packages were downloaded.'
    }
    elseif ($finalExitCode -eq 3010) {
        Write-LauncherStatus -State INFO -Message 'Installer completed. Restart Windows manually to finish.'
    }
    else {
        Write-LauncherStatus -State FAILED -Message 'Installer stopped with an error. Review its status output.'
    }
}
catch {
    Write-LauncherStatus -State FAILED -Message $_.Exception.Message
    $finalExitCode = 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($workspacePath)) {
        try {
            if (-not (Test-SafeLauncherWorkspace -WorkspacePath $workspacePath)) {
                throw "Refusing to remove unsafe launcher workspace: $workspacePath"
            }
            if (Test-Path -LiteralPath $workspacePath) {
                $workspaceItem = Get-Item -LiteralPath $workspacePath -Force -ErrorAction Stop
                if (($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing to remove a reparse-point launcher workspace: $workspacePath"
                }
                Remove-Item -LiteralPath $workspacePath -Recurse -Force -ErrorAction Stop
                Write-LauncherStatus -State CLEANUP -Message 'Launcher source files removed.'
            }
        }
        catch {
            Write-LauncherStatus -State FAILED -Message "Launcher cleanup failed: $($_.Exception.Message)"
            $finalExitCode = 1
        }
    }

    if ($shouldDeleteSelf) {
        try {
            Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction Stop
        }
        catch {
            Write-LauncherStatus -State FAILED -Message "Downloaded launcher cleanup failed: $($_.Exception.Message)"
            $finalExitCode = 1
        }
    }
}

exit $finalExitCode
}

Invoke-MicrosoftRuntimeLauncher -Components $Components -ExcludeComponents $ExcludeComponents -DotNetChannels $DotNetChannels -VisualCppVersions $VisualCppVersions -KeepDownloads:$KeepDownloads -ShowHelp:$ShowHelp -RemainingArguments $RemainingArguments -OriginalBoundParameters $PSBoundParameters
