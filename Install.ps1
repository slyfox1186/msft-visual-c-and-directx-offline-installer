#Requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$Components = 'All',
    [AllowEmptyString()][string[]]$ExcludeComponents = '',
    [string[]]$DotNetChannels = 'All',
    [string[]]$VisualCppVersions = 'All',
    [switch]$KeepDownloads,
    [AllowEmptyString()][string]$ReportPath = '',
    [switch]$InteractiveSession,
    [AllowEmptyString()][string]$DefaultReportDirectory = '',
    [ValidatePattern('\A(?:[0-9a-f]{40})?\z')][string]$SourceRevision = '',
    [Alias('h', 'Help')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/ConsoleUI.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src/RuntimeInstaller.psm1') -Force
$configuration = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'config/packages.psd1')

try {
    if ($null -ne $RemainingArguments -and $RemainingArguments.Count -gt 0) {
        if ($RemainingArguments.Count -ne 1 -or $RemainingArguments[0] -cne '--help') {
            throw "Unknown argument(s): $($RemainingArguments -join ' ')"
        }
        $ShowHelp = $true
    }
    if ($ShowHelp) { Write-InstallerHelp; exit 0 }

    $selectionOptions = @{}
    foreach ($name in @('Components', 'ExcludeComponents', 'DotNetChannels', 'VisualCppVersions')) {
        if ($PSBoundParameters.ContainsKey($name)) { $selectionOptions[$name] = $PSBoundParameters[$name] }
    }
    $options = @{}
    if ($selectionOptions.Count) { $options = Resolve-InstallerOptionSet -Configuration $configuration @selectionOptions }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This installer supports Windows only. Help is available with -Help.'
    }
    if ($ReportPath) { $ReportPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ReportPath)) }
    if (-not $DefaultReportDirectory) { $DefaultReportDirectory = [Environment]::GetFolderPath('UserProfile') }
    $options.KeepDownloads = [bool]$KeepDownloads
    $options.ReportPath = $ReportPath
    $options.DefaultReportDirectory = $DefaultReportDirectory
    $options.InteractiveSession = [bool]$InteractiveSession
    $options.SourceRevision = $SourceRevision
    $powershellExecutable = Get-InstallerPowerShell
    if ([IO.Path]::GetFileName($powershellExecutable) -ieq 'pwsh.exe' -and $PSVersionTable.PSEdition -ne 'Core') {
        $arguments = Get-InstallerChildArgument -ScriptPath $PSCommandPath -Options $options
        $process = Start-Process $powershellExecutable -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        exit $process.ExitCode
    }

    if (-not $selectionOptions.Count) {
        if ([Console]::IsInputRedirected) { throw 'Interactive input is unavailable. Supply -Components All or another explicit selection.' }
        $selection = Read-InstallerSelection -InitialKeepDownloads ([bool]$KeepDownloads)
        if ($selection.Cancelled) { exit 2 }
        $confirmed = Resolve-InstallerOptionSet -Configuration $configuration -Components $selection.Components -DotNetChannels $selection.DotNetChannels -VisualCppVersions $selection.VisualCppVersions
        foreach ($name in $confirmed.Keys) { $options[$name] = $confirmed[$name] }
        $InteractiveSession = $true
        $KeepDownloads = $options.KeepDownloads = [bool]$selection.KeepDownloads
        $options.InteractiveSession = $true
    }
    $selectedComponents = @($options.Components)
    $normalizedDotNetChannelText = $options.DotNetChannels -join ','
    $normalizedVisualCppVersions = $options.VisualCppVersions
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
    if (-not $isAdministrator) {
        Write-InstallerStatus Info 'Requesting administrator access through Windows UAC ...'
        $arguments = Get-InstallerChildArgument -ScriptPath $PSCommandPath -Options $options
        $process = Start-Process $powershellExecutable -ArgumentList $arguments -Verb RunAs -WindowStyle Maximized -Wait -PassThru
        exit $process.ExitCode
    }
}
catch {
    Write-InstallerStatus Failed $_.Exception.Message
    exit 1
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

    $groups = [ordered]@{}
    foreach ($component in $selectedComponents) {
        $groups[$component] = @(switch ($component) {
            'DotNet' {
                $resolved = @(Get-DotNetSdkPackage -WorkspacePath $workspacePath -Architecture $architecture)
                Select-DotNetSdkPackage -Packages $resolved -ChannelSelection $normalizedDotNetChannelText
            }
            'VisualCpp' {
                $selected = @(Get-VisualCppPackage $configuration $architecture $normalizedVisualCppVersions)
                Resolve-MicrosoftPackageSourceSet -Packages $selected -WorkspacePath $workspacePath
            }
            'DirectX' {
                Resolve-MicrosoftPackageSourceSet -Packages @(Get-DirectXPackage $configuration) -WorkspacePath $workspacePath
            }
        })
    }
    # Resolve the complete plan before running even the first package.
    foreach ($component in $groups.Keys) {
        foreach ($package in $groups[$component]) {
            $plannedPackageCount++
            $resolvedPackageLines += '{0:00} | {1} | {2}' -f $plannedPackageCount, $component, $package.Name
        }
    }
    $counts = @{ DotNet = 0; VisualCpp = 0; DirectX = 0 }
    foreach ($component in $groups.Keys) { $counts[$component] = $groups[$component].Count }
    $signedPackages = @(@($groups['VisualCpp']) + @($groups['DirectX']) | Where-Object { $null -ne $_ })
    $summary = @{
        Architecture = $architecture; PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        PowerShellEdition = $PSVersionTable.PSEdition; CurlVersion = $curlVersion
        DotNetPackageCount = $counts.DotNet; VisualCppPackageCount = $counts.VisualCpp
        DirectXSelected = $counts.DirectX -gt 0
        FixedHashPackageCount = @($signedPackages | Where-Object { $_.VersionPolicy -eq 'Fixed' }).Count
        RollingVisualCppSelected = @($signedPackages | Where-Object { $_.VersionPolicy -eq 'Rolling' }).Count -gt 0
    }
    Write-InstallerSystemSummary @summary
    $phase = 0
    foreach ($component in $groups.Keys) {
        $phase++
        Write-InstallerSection -Number $phase -Total $groups.Count -Title $component
        Invoke-RuntimeInstallation -Packages $groups[$component] -WorkspacePath $workspacePath -InstallerType $component -CompletedPackageCount ([ref]$completedPackageCount) -RestartRequired ([ref]$restartRequired)
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
            Write-InstallerStatus -State Retained -Message "Keeping the installer workspace at: $workspacePath"
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
    'HTTPS, approved discovery/payload hosts, bounded redirects, retries and timeouts',
    'Full source-plan resolution before sequential unattended execution; no automatic restart',
    'GUID workspace guard; failed verification deletes the untrusted file'
)
if ($SourceRevision) { $securityControls += 'Commit-pinned individual GitHub source files with syntax validation' }
if ($selectedComponents -contains 'DotNet') { $securityControls += '.NET support/EOL metadata, latest.version corroboration, Microsoft SHA-512' }
if ($selectedComponents -contains 'VisualCpp') { $securityControls += 'Visual C++ Microsoft signatures; fixed SHA-256 or rolling v14 version floor' }
if ($selectedComponents -contains 'DirectX') { $securityControls += 'DirectX SHA-256 and Microsoft signatures, including extracted DXSETUP.exe' }
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
