#Requires -Version 5.1

<#
.SYNOPSIS
Downloads, verifies, and installs selected Microsoft runtime packages.

.DESCRIPTION
Discovers currently supported stable .NET SDKs, downloads selected Microsoft
Visual C++ redistributables and DirectX June 2010 runtimes, verifies package
integrity or Authenticode provenance, installs silently, and removes downloads
unless KeepDownloads is specified.

.PARAMETER Components
Comma-delimited component groups: All, DotNet, VisualCpp, and DirectX.

.PARAMETER ExcludeComponents
Comma-delimited component groups to remove from the enabled set.

.PARAMETER DotNetChannels
All supported stable channels, or explicit versions such as 8.0,10.0.

.PARAMETER VisualCppVersions
All, or any combination of 2005, 2008, 2010, 2012, 2013, and v14.

.PARAMETER KeepDownloads
Retains the verified Microsoft package workspace after the run.

.PARAMETER ShowHelp
Shows concise command-line help without elevation or network access.

.EXAMPLE
.\Install.ps1

.EXAMPLE
.\Install.ps1 -Components DotNet,DirectX -DotNetChannels 8.0,10.0

.EXAMPLE
.\Install.ps1 -Components VisualCpp -VisualCppVersions 2013,v14 -KeepDownloads
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

$consoleModulePath = Join-Path $PSScriptRoot 'src\ConsoleUI.psm1'
$modulePath = Join-Path $PSScriptRoot 'src\RuntimeInstaller.psm1'
$configurationPath = Join-Path $PSScriptRoot 'config\packages.psd1'
Import-Module -Name $consoleModulePath -Force -ErrorAction Stop
Import-Module -Name $modulePath -ErrorAction Stop
$configuration = Import-PowerShellDataFile -LiteralPath $configurationPath -ErrorAction Stop

if ($null -ne $RemainingArguments -and $RemainingArguments.Count -gt 0) {
    if ($RemainingArguments.Count -eq 1 -and $RemainingArguments[0] -ceq '--help') {
        $ShowHelp = $true
    }
    else {
        Write-Host "Unknown argument(s): $($RemainingArguments -join ' ')" -ForegroundColor Red
        Write-Host 'Run Install.ps1 -Help for supported options.'
        exit 1
    }
}

if ($ShowHelp) {
    Write-InstallerHelp
    exit 0
}

try {
    $selectedComponents = @(Resolve-ComponentSelection -Components $Components -ExcludeComponents $ExcludeComponents)
    $normalizedDotNetChannels = @(Resolve-DotNetChannelSelection -ChannelSelection $DotNetChannels)
    if ($selectedComponents -notcontains 'DotNet' -and $normalizedDotNetChannels[0] -ne 'All') {
        throw '-DotNetChannels cannot be used when the DotNet component is disabled.'
    }

    $visualCppValidation = @(Get-VisualCppPackage -Configuration $configuration -OperatingSystemArchitecture x64 -VersionSelection $VisualCppVersions)
    if ($selectedComponents -notcontains 'VisualCpp' -and $VisualCppVersions.Trim() -ine 'All') {
        throw '-VisualCppVersions cannot be used when the VisualCpp component is disabled.'
    }
    if ($VisualCppVersions.Trim() -ieq 'All') {
        $normalizedVisualCppVersions = 'All'
    }
    else {
        $normalizedVisualCppVersions = (@($visualCppValidation.Version | Select-Object -Unique) -join ',')
    }
}
catch {
    Write-Host "Invalid installer options: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Run Install.ps1 -Help for supported options.'
    exit 1
}

$normalizedComponents = $selectedComponents -join ','
$normalizedDotNetChannelText = $normalizedDotNetChannels -join ','

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This installer supports Windows only. Help is available with -Help.'
}

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdministrator) {
    Write-Host 'Administrator access is required. Requesting approval through Windows UAC ...' -ForegroundColor Yellow
    try {
        $elevationArguments = @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath),
            '-Components', ('"{0}"' -f $normalizedComponents),
            '-DotNetChannels', ('"{0}"' -f $normalizedDotNetChannelText),
            '-VisualCppVersions', ('"{0}"' -f $normalizedVisualCppVersions)
        )
        if ($KeepDownloads) { $elevationArguments += '-KeepDownloads' }
        $elevatedProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList $elevationArguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
        exit $elevatedProcess.ExitCode
    }
    catch {
        Write-Error "Unable to start the elevated installer: $($_.Exception.Message)"
        exit 1
    }
}

$workspacePath = $null
$restartRequired = $false
$completedPackageCount = 0
$cleanupSucceeded = $true
$retainedWorkspacePath = ''
$failureMessage = ''
$outcome = 'Failed'
$finalExitCode = 1
$overallTimer = [Diagnostics.Stopwatch]::StartNew()

try {
    $architecture = Get-TargetArchitecture
    $workspacePath = New-InstallerWorkspace

    Write-InstallerBanner
    Write-InstallerStatus -State Info -Message 'Building the selected install plan ...'

    $curlCommand = Get-Command -Name 'curl.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $curlVersionLine = [string](& $curlCommand.Source --version | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or $curlVersionLine -notmatch '^curl\s+([^\s]+)') {
        throw 'Unable to determine the installed curl.exe version.'
    }
    $curlVersion = $matches[1]

    $dotNetPackages = @()
    if ($selectedComponents -contains 'DotNet') {
        $resolvedDotNetPackages = @(Get-DotNetSdkPackage -WorkspacePath $workspacePath -Architecture $architecture)
        $dotNetPackages = @(Select-DotNetSdkPackage -Packages $resolvedDotNetPackages -ChannelSelection $normalizedDotNetChannelText)
    }
    $visualCppPackages = @()
    if ($selectedComponents -contains 'VisualCpp') {
        $visualCppPackages = @(Get-VisualCppPackage -Configuration $configuration -OperatingSystemArchitecture $architecture -VersionSelection $normalizedVisualCppVersions)
    }
    Write-InstallerSystemSummary -Architecture $architecture -PowerShellVersion $PSVersionTable.PSVersion.ToString() -CurlVersion $curlVersion -WorkspacePath $workspacePath -DotNetPackageCount $dotNetPackages.Count -VisualCppPackageCount $visualCppPackages.Count -DirectXSelected ($selectedComponents -contains 'DirectX')

    $phaseNumber = 0
    $phaseTotal = $selectedComponents.Count
    if ($selectedComponents -contains 'DotNet') {
        $phaseNumber++
        Write-InstallerSection -Number $phaseNumber -Total $phaseTotal -Title 'Supported .NET SDKs'
        Invoke-DotNetSdkInstallation -Packages $dotNetPackages -WorkspacePath $workspacePath -CompletedPackageCount ([ref]$completedPackageCount) -RestartRequired ([ref]$restartRequired)
    }
    if ($selectedComponents -contains 'VisualCpp') {
        $phaseNumber++
        Write-InstallerSection -Number $phaseNumber -Total $phaseTotal -Title 'Microsoft Visual C++ Redistributables'
        Invoke-VisualCppInstallation -Configuration $configuration -OperatingSystemArchitecture $architecture -WorkspacePath $workspacePath -VersionSelection $normalizedVisualCppVersions -CompletedPackageCount ([ref]$completedPackageCount) -RestartRequired ([ref]$restartRequired)
    }
    if ($selectedComponents -contains 'DirectX') {
        $phaseNumber++
        Write-InstallerSection -Number $phaseNumber -Total $phaseTotal -Title 'DirectX June 2010 Legacy Runtimes'
        Invoke-DirectXInstallation -Configuration $configuration -WorkspacePath $workspacePath -CompletedPackageCount ([ref]$completedPackageCount) -RestartRequired ([ref]$restartRequired)
    }

    if ($restartRequired) {
        $outcome = 'Restart'
        $finalExitCode = 3010
    }
    else {
        $outcome = 'Success'
        $finalExitCode = 0
    }
}
catch {
    $failureMessage = $_.Exception.Message
    $outcome = 'Failed'
    $finalExitCode = 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($workspacePath)) {
        if ($KeepDownloads) {
            $retainedWorkspacePath = $workspacePath
            Write-InstallerStatus -State Retained -Message "Keeping verified downloads at: $workspacePath"
        }
        else {
            Write-InstallerStatus -State Cleanup -Message 'Removing the protected temporary workspace ...'
            try {
                Remove-InstallerWorkspace -WorkspacePath $workspacePath
                Write-InstallerStatus -State Ok -Message 'Temporary workspace removed.'
            }
            catch {
                $cleanupSucceeded = $false
                $cleanupMessage = $_.Exception.Message
                Write-InstallerStatus -State Failed -Message "Temporary workspace cleanup failed: $cleanupMessage"
                if ([string]::IsNullOrWhiteSpace($failureMessage)) {
                    $failureMessage = $cleanupMessage
                }
                else {
                    $failureMessage = "$failureMessage Cleanup also failed: $cleanupMessage"
                }
                $outcome = 'Failed'
                $finalExitCode = 1
            }
        }
    }
}

$overallTimer.Stop()
Write-InstallerSummary -Outcome $outcome -CompletedPackageCount $completedPackageCount -Duration $overallTimer.Elapsed -CleanupSucceeded $cleanupSucceeded -RetainedWorkspacePath $retainedWorkspacePath -Message $failureMessage
exit $finalExitCode
