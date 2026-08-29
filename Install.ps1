#Requires -Version 5.1

<#
.SYNOPSIS
Downloads, verifies, and installs selected Microsoft runtime packages.

.DESCRIPTION
Discovers currently supported stable .NET SDKs, downloads selected Microsoft
Visual C++ redistributables and DirectX June 2010 runtimes, verifies package
integrity or Authenticode provenance, provides an interactive selector when no
package options are supplied, installs the confirmed plan without prompts, and
removes the installer workspace unless KeepDownloads is specified.

.PARAMETER Components
Comma-delimited component groups: All, DotNet, VisualCpp, and DirectX.

.PARAMETER ExcludeComponents
Comma-delimited component groups to remove from the enabled set.

.PARAMETER DotNetChannels
All supported stable channels, or explicit versions such as 8.0,10.0.

.PARAMETER VisualCppVersions
All, or any combination of 2005, 2008, 2010, 2012, 2013, and v14.

.PARAMETER KeepDownloads
Retains the installer workspace, including downloaded metadata and packages.

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

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$consoleModulePath = Join-Path $PSScriptRoot 'src\ConsoleUI.psm1'
$modulePath = Join-Path $PSScriptRoot 'src\RuntimeInstaller.psm1'
$configurationPath = Join-Path $PSScriptRoot 'config\packages.psd1'
Import-Module -Name $consoleModulePath -Force -ErrorAction Stop
Import-Module -Name $modulePath -Force -ErrorAction Stop
$configuration = Import-PowerShellDataFile -LiteralPath $configurationPath -ErrorAction Stop

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

function Resolve-InstallerOptionSet {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$ComponentText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExcludedComponentText,
        [Parameter(Mandatory = $true)][string]$DotNetChannelText,
        [Parameter(Mandatory = $true)][string]$VisualCppVersionText
    )

    $resolvedComponents = @(Resolve-ComponentSelection -Components $ComponentText -ExcludeComponents $ExcludedComponentText)
    $resolvedDotNetChannels = @(Resolve-DotNetChannelSelection -ChannelSelection $DotNetChannelText)
    if ($resolvedComponents -notcontains 'DotNet' -and $resolvedDotNetChannels[0] -ne 'All') {
        throw '-DotNetChannels cannot be used when the DotNet component is disabled.'
    }

    $visualCppValidation = @(Get-VisualCppPackage -Configuration $configuration -OperatingSystemArchitecture x64 -VersionSelection $VisualCppVersionText)
    if ($resolvedComponents -notcontains 'VisualCpp' -and $VisualCppVersionText.Trim() -ine 'All') {
        throw '-VisualCppVersions cannot be used when the VisualCpp component is disabled.'
    }
    $resolvedVisualCppVersions = 'All'
    if ($VisualCppVersionText.Trim() -ine 'All') {
        $resolvedVisualCppVersions = @($visualCppValidation.Version | Select-Object -Unique) -join ','
    }

    return [pscustomobject]@{
        Components        = $resolvedComponents
        DotNetChannels    = $resolvedDotNetChannels
        VisualCppVersions = $resolvedVisualCppVersions
    }
}

function Get-InstallerChildArgument {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [psobject]$OptionSet,
        [switch]$IncludeSelection,
        [bool]$RetainDownloads = $false
    )

    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $ScriptPath)
    )
    if ($IncludeSelection) {
        if ($null -eq $OptionSet) { throw 'Resolved installer options are required for a child process.' }
        $arguments += @(
            '-Components', ('"{0}"' -f (@($OptionSet.Components) -join ',')),
            '-DotNetChannels', ('"{0}"' -f (@($OptionSet.DotNetChannels) -join ',')),
            '-VisualCppVersions', ('"{0}"' -f [string]$OptionSet.VisualCppVersions)
        )
    }
    if ($RetainDownloads) { $arguments += '-KeepDownloads' }
    return $arguments
}

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

$selectionOptionsWereBound = @(
    @('Components', 'ExcludeComponents', 'DotNetChannels', 'VisualCppVersions') |
        Where-Object { $PSBoundParameters.ContainsKey($_) }
)
$componentText = @($Components) -join ','
$excludedComponentText = @($ExcludeComponents) -join ','
$dotNetChannelText = ConvertTo-DotNetChannelText -Value $DotNetChannels
$visualCppVersionText = @($VisualCppVersions) -join ','
$resolvedOptions = $null
if ($selectionOptionsWereBound.Count -gt 0) {
    try {
        $resolvedOptions = Resolve-InstallerOptionSet -ComponentText $componentText -ExcludedComponentText $excludedComponentText -DotNetChannelText $dotNetChannelText -VisualCppVersionText $visualCppVersionText
    }
    catch {
        Write-Host "Invalid installer options: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Run Install.ps1 -Help for supported options.'
        exit 1
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This installer supports Windows only. Help is available with -Help.'
}

$powershellExecutable = Get-PreferredPowerShellExecutable

$preferredIsPowerShell7 = [IO.Path]::GetFileName($powershellExecutable) -ieq 'pwsh.exe'
if ($preferredIsPowerShell7 -and $PSVersionTable.PSEdition -ne 'Core') {
    Write-Host 'PowerShell 7 detected. Continuing with pwsh.exe ...' -ForegroundColor Cyan
    try {
        $childArguments = Get-InstallerChildArgument -ScriptPath $PSCommandPath -OptionSet $resolvedOptions -IncludeSelection:($selectionOptionsWereBound.Count -gt 0) -RetainDownloads ([bool]$KeepDownloads)
        $preferredProcess = Start-Process -FilePath $powershellExecutable -ArgumentList $childArguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
        exit $preferredProcess.ExitCode
    }
    catch {
        Write-Error "Unable to continue with PowerShell 7: $($_.Exception.Message)"
        exit 1
    }
}

if ($selectionOptionsWereBound.Count -eq 0) {
    if ([Console]::IsInputRedirected) {
        Write-Error 'Interactive input is unavailable. Supply -Components All or another explicit package selection.'
        exit 1
    }
    try {
        $selection = Read-InstallerSelection -InitialKeepDownloads ([bool]$KeepDownloads)
        if ($selection.Cancelled) { exit 2 }
        $KeepDownloads = [bool]$selection.KeepDownloads
        $resolvedOptions = Resolve-InstallerOptionSet -ComponentText ([string]$selection.Components) -ExcludedComponentText '' -DotNetChannelText ([string]$selection.DotNetChannels) -VisualCppVersionText ([string]$selection.VisualCppVersions)
    }
    catch {
        Write-Host "Invalid installer selection: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

$selectedComponents = @($resolvedOptions.Components)
$normalizedDotNetChannels = @($resolvedOptions.DotNetChannels)
$normalizedVisualCppVersions = [string]$resolvedOptions.VisualCppVersions
$normalizedDotNetChannelText = $normalizedDotNetChannels -join ','
$childArguments = Get-InstallerChildArgument -ScriptPath $PSCommandPath -OptionSet $resolvedOptions -IncludeSelection -RetainDownloads ([bool]$KeepDownloads)

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdministrator) {
    Write-Host 'Administrator access is required. Requesting approval through Windows UAC ...' -ForegroundColor Yellow
    try {
        $elevatedProcess = Start-Process -FilePath $powershellExecutable -ArgumentList $childArguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
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

    $curlVersion = Get-CurlVersion

    $dotNetPackages = @()
    if ($selectedComponents -contains 'DotNet') {
        $resolvedDotNetPackages = @(Get-DotNetSdkPackage -WorkspacePath $workspacePath -Architecture $architecture)
        $dotNetPackages = @(Select-DotNetSdkPackage -Packages $resolvedDotNetPackages -ChannelSelection $normalizedDotNetChannelText)
    }
    $visualCppPackages = @()
    if ($selectedComponents -contains 'VisualCpp') {
        $visualCppPackages = @(Get-VisualCppPackage -Configuration $configuration -OperatingSystemArchitecture $architecture -VersionSelection $normalizedVisualCppVersions)
    }
    Write-InstallerSystemSummary -Architecture $architecture -PowerShellVersion $PSVersionTable.PSVersion.ToString() -PowerShellEdition $PSVersionTable.PSEdition -CurlVersion $curlVersion -WorkspacePath $workspacePath -DotNetPackageCount $dotNetPackages.Count -VisualCppPackageCount $visualCppPackages.Count -DirectXSelected ($selectedComponents -contains 'DirectX')

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
            if ($outcome -eq 'Failed') {
                Write-InstallerStatus -State Retained -Message "Keeping the installer workspace for diagnosis at: $workspacePath"
            }
            else {
                Write-InstallerStatus -State Retained -Message "Keeping the installer workspace at: $workspacePath"
            }
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
