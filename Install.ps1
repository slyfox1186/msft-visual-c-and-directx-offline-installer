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

.PARAMETER ReportPath
Writes a UTF-8 technical report to a .txt file or a timestamped file in the
specified directory. Interactive runs can choose a path from the final screen.

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

    [AllowEmptyString()]
    [string]$ReportPath = '',

    [switch]$InteractiveSession,

    [AllowEmptyString()]
    [string]$DefaultReportDirectory = '',

    [ValidatePattern('\A(?:[0-9a-f]{40})?\z')]
    [string]$SourceRevision = '',

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

function ConvertTo-NativeQuotedArgument {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    if ($Value -match '[\x00-\x1f"]') {
        throw 'A native process argument contains a control character or quotation mark.'
    }

    # Start-Process joins ArgumentList arrays into one native command line.
    # In Windows' legacy argument parser, trailing backslashes must be doubled
    # before the closing quote or the quote can be escaped into the value.
    $trailingBackslashCount = 0
    for ($index = $Value.Length - 1; $index -ge 0 -and $Value[$index] -eq '\'; $index--) {
        $trailingBackslashCount++
    }
    $escapedValue = $Value
    if ($trailingBackslashCount -gt 0) {
        $escapedValue += '\' * $trailingBackslashCount
    }
    return '"' + $escapedValue + '"'
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
        [bool]$RetainDownloads = $false,
        [switch]$InteractiveSession,
        [AllowEmptyString()][string]$DefaultReportDirectory = '',
        [AllowEmptyString()][string]$RequestedReportPath = '',
        [ValidatePattern('\A(?:[0-9a-f]{40})?\z')][string]$SourceRevision = ''
    )

    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (ConvertTo-NativeQuotedArgument -Value $ScriptPath)
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
    if ($InteractiveSession) { $arguments += '-InteractiveSession' }
    foreach ($pathOption in @(
        [pscustomobject]@{ Name = '-DefaultReportDirectory'; Value = $DefaultReportDirectory },
        [pscustomobject]@{ Name = '-ReportPath'; Value = $RequestedReportPath }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$pathOption.Value)) { continue }
        $arguments += @([string]$pathOption.Name, (ConvertTo-NativeQuotedArgument -Value ([string]$pathOption.Value)))
    }
    if (-not [string]::IsNullOrWhiteSpace($SourceRevision)) {
        $arguments += @('-SourceRevision', $SourceRevision)
    }
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

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    try {
        $ReportPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ReportPath))
    }
    catch {
        throw "Invalid technical report path: $($_.Exception.Message)"
    }
}

$powershellExecutable = Get-PreferredPowerShellExecutable

$preferredIsPowerShell7 = [IO.Path]::GetFileName($powershellExecutable) -ieq 'pwsh.exe'
if ($preferredIsPowerShell7 -and $PSVersionTable.PSEdition -ne 'Core') {
    Write-Host 'PowerShell 7 detected. Continuing with pwsh.exe ...' -ForegroundColor Cyan
    try {
        $childArguments = Get-InstallerChildArgument -ScriptPath $PSCommandPath -OptionSet $resolvedOptions -IncludeSelection:($selectionOptionsWereBound.Count -gt 0) -RetainDownloads ([bool]$KeepDownloads) -InteractiveSession:$InteractiveSession -DefaultReportDirectory $DefaultReportDirectory -RequestedReportPath $ReportPath -SourceRevision $SourceRevision
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
        $InteractiveSession = $true
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
if ($InteractiveSession -and [string]::IsNullOrWhiteSpace($DefaultReportDirectory)) {
    $DefaultReportDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($DefaultReportDirectory)) {
        $DefaultReportDirectory = $env:USERPROFILE
    }
    if ([string]::IsNullOrWhiteSpace($DefaultReportDirectory)) {
        throw 'The user profile directory could not be resolved for the technical report.'
    }
}
$childArguments = Get-InstallerChildArgument -ScriptPath $PSCommandPath -OptionSet $resolvedOptions -IncludeSelection -RetainDownloads ([bool]$KeepDownloads) -InteractiveSession:$InteractiveSession -DefaultReportDirectory $DefaultReportDirectory -RequestedReportPath $ReportPath -SourceRevision $SourceRevision

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdministrator) {
    Write-Host 'Administrator access is required. Requesting approval through Windows UAC ...' -ForegroundColor Yellow
    try {
        $elevatedProcess = Start-Process -FilePath $powershellExecutable -ArgumentList $childArguments -Verb RunAs -WindowStyle Maximized -Wait -PassThru -ErrorAction Stop
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
$plannedPackageCount = 0
$cleanupSucceeded = $true
$cleanupStatus = 'No temporary workspace was created.'
$retainedWorkspacePath = ''
$failureMessage = ''
$outcome = 'Failed'
$finalExitCode = 1
$architecture = 'Unknown'
$curlVersion = 'Unavailable'
$resolvedPackageLines = @()
$fixedHashPackageCount = 0
$rollingVisualCppSelected = $false
$runId = [guid]::NewGuid().ToString()
$startedAt = [datetimeoffset]::Now
$overallTimer = [Diagnostics.Stopwatch]::StartNew()
Initialize-InstallerDiagnostic -RunId $runId

try {
    $architecture = Get-TargetArchitecture
    $workspacePath = New-InstallerWorkspace

    Write-InstallerBanner
    Write-InstallerStatus -State Info -Message 'Preparing the install plan: resolving current releases and official Microsoft sources'

    $curlVersion = Get-CurlVersion

    $dotNetPackages = @()
    if ($selectedComponents -contains 'DotNet') {
        $resolvedDotNetPackages = @(Get-DotNetSdkPackage -WorkspacePath $workspacePath -Architecture $architecture)
        $dotNetPackages = @(Select-DotNetSdkPackage -Packages $resolvedDotNetPackages -ChannelSelection $normalizedDotNetChannelText)
    }
    $visualCppPackages = @()
    if ($selectedComponents -contains 'VisualCpp') {
        $unresolvedVisualCppPackages = @(Get-VisualCppPackage -Configuration $configuration -OperatingSystemArchitecture $architecture -VersionSelection $normalizedVisualCppVersions)
        $visualCppPackages = @(Resolve-MicrosoftPackageSourceSet -Packages $unresolvedVisualCppPackages -WorkspacePath $workspacePath)
    }
    $directXPackage = $null
    if ($selectedComponents -contains 'DirectX') {
        $unresolvedDirectXPackage = Get-DirectXPackage -Configuration $configuration
        $directXPackage = @(Resolve-MicrosoftPackageSourceSet -Packages @($unresolvedDirectXPackage) -WorkspacePath $workspacePath)[0]
    }
    $plannedPackageCount = $dotNetPackages.Count + $visualCppPackages.Count
    if ($null -ne $directXPackage) { $plannedPackageCount++ }

    $packageNumber = 0
    foreach ($package in $dotNetPackages) {
        $packageNumber++
        $resolvedPackageLines += ('{0:00} | .NET SDK | {1} | Version {2} | Architecture {3} | Verification SHA-512' -f $packageNumber, $package.Name, $package.Version, $package.Architecture)
    }
    foreach ($package in $visualCppPackages) {
        $packageNumber++
        $versionResolution = if ([string]$package.Version -eq 'v14') {
            'Latest supported permalink; file version validated after download'
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$package.DocumentedVersion)) {
            'Final Microsoft release; file version recorded after download'
        }
        else {
            'Final documented version {0}' -f $package.DocumentedVersion
        }
        $verification = if ([string]$package.Version -eq 'v14') {
            'Microsoft signature + file-version security floor'
        }
        else {
            'Reviewed SHA-256 + Microsoft signature'
        }
        $resolvedPackageLines += ('{0:00} | Visual C++ | {1} | {2} | Architecture {3} | Source resolved at run time | Verification {4}' -f $packageNumber, $package.Name, $versionResolution, $package.Architecture, $verification)
    }
    if ($null -ne $directXPackage) {
        $packageNumber++
        $resolvedPackageLines += ('{0:00} | DirectX | {1} | Final June 2010 release | Architecture neutral | Source resolved at run time | Verification reviewed SHA-256 + Microsoft signature' -f $packageNumber, $directXPackage.Name)
    }
    $fixedHashPackageCount = @($visualCppPackages | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Sha256) }).Count
    if ($null -ne $directXPackage -and -not [string]::IsNullOrWhiteSpace([string]$directXPackage.Sha256)) {
        $fixedHashPackageCount++
    }
    $rollingVisualCppSelected = @($visualCppPackages | Where-Object { [string]$_.VersionPolicy -eq 'Rolling' }).Count -gt 0
    Write-InstallerSystemSummary -Architecture $architecture -PowerShellVersion $PSVersionTable.PSVersion.ToString() -PowerShellEdition $PSVersionTable.PSEdition -CurlVersion $curlVersion -DotNetPackageCount $dotNetPackages.Count -VisualCppPackageCount $visualCppPackages.Count -DirectXSelected ($selectedComponents -contains 'DirectX') -FixedHashPackageCount $fixedHashPackageCount -RollingVisualCppSelected $rollingVisualCppSelected

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
        Invoke-VisualCppInstallation -Packages $visualCppPackages -WorkspacePath $workspacePath -CompletedPackageCount ([ref]$completedPackageCount) -RestartRequired ([ref]$restartRequired)
    }
    if ($selectedComponents -contains 'DirectX') {
        $phaseNumber++
        Write-InstallerSection -Number $phaseNumber -Total $phaseTotal -Title 'DirectX June 2010 Legacy Runtimes'
        Invoke-DirectXInstallation -Package $directXPackage -WorkspacePath $workspacePath -CompletedPackageCount ([ref]$completedPackageCount) -RestartRequired ([ref]$restartRequired)
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
            $cleanupStatus = "Retained at $workspacePath"
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
                $cleanupStatus = 'Removed successfully'
                Write-InstallerStatus -State Ok -Message 'Temporary workspace removed.'
            }
            catch {
                $cleanupSucceeded = $false
                $cleanupMessage = $_.Exception.Message
                $cleanupStatus = "Cleanup failed: $cleanupMessage"
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
$completedAt = [datetimeoffset]::Now
$powerShellDisplay = '{0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition
$operatingSystem = [Environment]::OSVersion.VersionString
try {
    $operatingSystemRecord = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $operatingSystem = '{0} | Version {1} | Build {2}' -f $operatingSystemRecord.Caption, $operatingSystemRecord.Version, $operatingSystemRecord.BuildNumber
}
catch {
    $null = $_
}

$reportDefaultDirectory = $DefaultReportDirectory
if ([string]::IsNullOrWhiteSpace($reportDefaultDirectory)) {
    $reportDefaultDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
}
if ([string]::IsNullOrWhiteSpace($reportDefaultDirectory)) {
    $reportDefaultDirectory = $env:USERPROFILE
}

$securityControls = @(
    'HTTPS-only downloads with redirect limits, retries, timeouts, and approved effective-host validation',
    'Run-time source resolution from first-party Microsoft catalogs and dedicated Microsoft aliases with separate discovery and payload host allowlists',
    'Exact-one family, architecture, and filename matching before the selected package plan may execute',
    'Commit-pinned individual GitHub source files with PowerShell syntax validation',
    'Sequential unattended package execution with automatic restarts suppressed'
)
if ($selectedComponents -contains 'DotNet') {
    $securityControls += 'Supported-channel metadata plus latest.version corroboration and Microsoft-published SHA-512 verification for .NET SDK installers'
}
if ($fixedHashPackageCount -gt 0) {
    $securityControls += 'Reviewed SHA-256 verification for fixed Visual C++ and DirectX packages before Microsoft digital-signature verification'
}
if ($selectedComponents -contains 'VisualCpp' -or $selectedComponents -contains 'DirectX') {
    $securityControls += 'Microsoft Corporation digital-signature verification for Visual C++ and DirectX executables'
}
if ($rollingVisualCppSelected) {
    $securityControls += 'Microsoft latest-supported v14 aliases plus Microsoft signature and reviewed minimum-version enforcement'
}

$reportContext = @{
    RunId                 = $runId
    SourceRevision        = if ([string]::IsNullOrWhiteSpace($SourceRevision)) { 'Local source; Git revision unavailable' } else { $SourceRevision }
    StartedAt             = $startedAt
    CompletedAt           = $completedAt
    Outcome               = $outcome
    ExitCode              = $finalExitCode
    CompletedPackageCount = $completedPackageCount
    PlannedPackageCount   = $plannedPackageCount
    Duration               = $overallTimer.Elapsed
    RestartRequired       = $restartRequired
    CleanupStatus         = $cleanupStatus
    DownloadsRetained     = -not [string]::IsNullOrWhiteSpace($retainedWorkspacePath)
    RetainedWorkspacePath = $retainedWorkspacePath
    FailureMessage        = $failureMessage
    ComputerName          = [Environment]::MachineName
    OperatingSystem       = $operatingSystem
    Architecture          = $architecture
    PowerShell            = $powerShellDisplay
    CurlVersion           = $curlVersion
    Culture               = [Globalization.CultureInfo]::CurrentCulture.Name
    Components            = $selectedComponents -join ','
    DotNetChannels        = $normalizedDotNetChannelText
    VisualCppVersions     = $normalizedVisualCppVersions
    ResolvedPackages      = $resolvedPackageLines
    SecurityControls      = $securityControls
    UserProfilePath       = $reportDefaultDirectory
    TempPath              = [IO.Path]::GetTempPath()
}
$diagnosticEvents = @(Get-InstallerDiagnosticEvent)
$reportExporter = {
    param($DestinationPath)
    Export-InstallerTechnicalReport -DestinationPath ([string]$DestinationPath) -DefaultDirectory $reportDefaultDirectory -Context $reportContext -Events $diagnosticEvents -Timestamp $completedAt.LocalDateTime
}

$technicalReportPath = ''
$technicalReportError = ''
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    try {
        $technicalReportPath = [string](& $reportExporter $ReportPath)
        Write-InstallerStatus -State Ok -Message "Technical report saved: $technicalReportPath"
    }
    catch {
        $technicalReportError = $_.Exception.Message
        Write-InstallerStatus -State Failed -Message "Technical report export failed: $technicalReportError"
        if (-not $InteractiveSession) {
            $finalExitCode = 1
        }
    }
}

if ($InteractiveSession) {
    if ([string]::IsNullOrWhiteSpace($reportDefaultDirectory)) {
        Write-InstallerStatus -State Failed -Message 'The user profile directory is unavailable; a technical report cannot be saved.'
        $technicalReportError = 'The user profile directory is unavailable.'
        $reportDefaultDirectory = [IO.Path]::GetTempPath()
    }
    $null = Invoke-InstallerCompletionPrompt -Outcome $outcome -CompletedPackageCount $completedPackageCount -PlannedPackageCount $plannedPackageCount -Duration $overallTimer.Elapsed -CleanupSucceeded $cleanupSucceeded -RestartRequired $restartRequired -DownloadsRetained (-not [string]::IsNullOrWhiteSpace($retainedWorkspacePath)) -RetainedWorkspacePath $retainedWorkspacePath -Message $failureMessage -DefaultReportDirectory $reportDefaultDirectory -ReportExporter $reportExporter -ExistingReportPath $technicalReportPath -InitialReportError $technicalReportError
}
exit $finalExitCode
