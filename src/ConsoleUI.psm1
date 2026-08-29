Set-StrictMode -Version 2.0

$script:DefaultConsoleWidth = 78
$script:MinimumConsoleWidth = 72
$script:MaximumConsoleWidth = 110
$script:StatusBadgeWidth = 8
$script:DiagnosticRunId = ''
$script:DiagnosticEvents = New-Object 'Collections.Generic.List[object]'

function Get-InstallerConsoleWidth {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $width = $script:DefaultConsoleWidth
    try {
        if (-not [Console]::IsOutputRedirected -and [Console]::WindowWidth -gt 1) {
            $width = [Console]::WindowWidth - 1
        }
    }
    catch {
        $width = $script:DefaultConsoleWidth
    }

    return [math]::Min(
        $script:MaximumConsoleWidth,
        [math]::Max($script:MinimumConsoleWidth, $width)
    )
}

$script:ConsoleWidth = Get-InstallerConsoleWidth

function Format-InstallerByteSize {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [long]::MaxValue)]
        [long]$Bytes
    )

    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -lt 1KB) {
        return [string]::Format($culture, '{0} B', $Bytes)
    }
    if ($Bytes -lt 1MB) {
        return [string]::Format($culture, '{0:F2} KB', ($Bytes / 1KB))
    }
    if ($Bytes -lt 1GB) {
        return [string]::Format($culture, '{0:F2} MB', ($Bytes / 1MB))
    }
    return [string]::Format($culture, '{0:F2} GB', ($Bytes / 1GB))
}

function Format-InstallerDuration {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [timespan]$Duration
    )

    if ($Duration.Ticks -lt 0) {
        throw 'Installer duration cannot be negative.'
    }

    $totalHours = [math]::Floor($Duration.TotalHours)
    if ($totalHours -gt 0) {
        return '{0}:{1:00}:{2:00}' -f $totalHours, $Duration.Minutes, $Duration.Seconds
    }
    return '{0:00}:{1:00}' -f $Duration.Minutes, $Duration.Seconds
}

function Format-InstallerPlan {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$DotNetPackageCount,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$VisualCppPackageCount,

        [Parameter(Mandatory = $true)]
        [bool]$DirectXSelected
    )

    $parts = @()
    if ($DotNetPackageCount -gt 0) { $parts += "$DotNetPackageCount supported .NET SDK(s)" }
    if ($VisualCppPackageCount -gt 0) { $parts += "$VisualCppPackageCount Visual C++ package(s)" }
    if ($DirectXSelected) { $parts += 'DirectX June 2010' }
    if ($parts.Count -eq 0) { throw 'The formatted installer plan cannot be empty.' }
    return $parts -join ' | '
}

function Get-InstallerStatusBadge {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Download', 'Verify', 'Install', 'Info', 'Ok', 'Restart', 'Failed', 'Cleanup', 'Retained')]
        [string]$State
    )

    $label = $State.ToUpperInvariant()
    $totalPadding = $script:StatusBadgeWidth - $label.Length
    $leftPadding = [math]::Floor($totalPadding / 2)
    $rightPadding = $totalPadding - $leftPadding

    return '[' + (' ' * $leftPadding) + $label + (' ' * $rightPadding) + ']'
}

function Get-InstallerStatusColor {
    [CmdletBinding()]
    [OutputType([ConsoleColor])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Download', 'Verify', 'Install', 'Info', 'Ok', 'Restart', 'Failed', 'Cleanup', 'Retained')]
        [string]$State
    )

    switch ($State) {
        'Ok' { return [ConsoleColor]::Green }
        'Restart' { return [ConsoleColor]::Yellow }
        'Retained' { return [ConsoleColor]::Yellow }
        'Failed' { return [ConsoleColor]::Red }
        'Cleanup' { return [ConsoleColor]::DarkCyan }
        default { return [ConsoleColor]::Cyan }
    }
}

function Add-InstallerDiagnosticEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Download', 'Verify', 'Install', 'Info', 'Ok', 'Restart', 'Failed', 'Cleanup', 'Retained', 'Phase')]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:DiagnosticEvents.Add([pscustomobject]@{
        Timestamp = [datetimeoffset]::Now
        State     = $State
        Message   = $Message
    })
}

function Initialize-InstallerDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('\A[0-9a-fA-F-]{36}\z')]
        [string]$RunId
    )

    $parsedRunId = [guid]::Empty
    if (-not [guid]::TryParse($RunId, [ref]$parsedRunId)) {
        throw "Invalid installer diagnostic run ID: $RunId"
    }

    $script:DiagnosticRunId = $parsedRunId.ToString()
    $script:DiagnosticEvents = New-Object 'Collections.Generic.List[object]'
}

function Get-InstallerDiagnosticEvent {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    return @($script:DiagnosticEvents.ToArray())
}

function Resolve-InstallerReportPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$DestinationPath = '',

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DefaultDirectory,

        [datetime]$Timestamp = [datetime]::Now
    )

    $fileName = 'Microsoft-Runtime-Installer-Report-{0}.txt' -f $Timestamp.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $candidate = $DestinationPath.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $DefaultDirectory
    }
    elseif ($candidate.StartsWith('"', [StringComparison]::Ordinal) -and $candidate.EndsWith('"', [StringComparison]::Ordinal) -and $candidate.Length -ge 2) {
        $candidate = $candidate.Substring(1, $candidate.Length - 2)
    }
    elseif ($candidate.Contains('"')) {
        throw 'The technical report path contains an unmatched quotation mark.'
    }

    try {
        $expandedPath = [Environment]::ExpandEnvironmentVariables($candidate)
        $fullPath = [IO.Path]::GetFullPath($expandedPath)
    }
    catch {
        throw "Invalid technical report path: $($_.Exception.Message)"
    }

    $pathIsDirectory = Test-Path -LiteralPath $fullPath -PathType Container
    $endsWithSeparator = $candidate.EndsWith([IO.Path]::DirectorySeparatorChar) -or
        $candidate.EndsWith([IO.Path]::AltDirectorySeparatorChar)
    $extension = [IO.Path]::GetExtension($fullPath)
    if ($pathIsDirectory -or $endsWithSeparator -or [string]::IsNullOrWhiteSpace($extension)) {
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            throw "The technical report directory is an existing file: $fullPath"
        }
        $fullPath = Join-Path $fullPath $fileName
    }
    elseif ($extension -ine '.txt') {
        throw 'The technical report filename must use the .txt extension.'
    }

    if (Test-Path -LiteralPath $fullPath) {
        throw "The technical report file already exists: $fullPath"
    }

    return $fullPath
}

function ConvertTo-InstallerReportText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [Collections.IDictionary]$Context
    )

    $text = [string]$Value
    $text = $text.Replace("`r", ' ').Replace("`n", ' ')
    foreach ($pathKey in @('UserProfilePath', 'TempPath')) {
        if (-not $Context.Contains($pathKey)) { continue }
        $literalPath = [string]$Context[$pathKey]
        if ([string]::IsNullOrWhiteSpace($literalPath)) { continue }
        $replacement = if ($pathKey -eq 'UserProfilePath') { '%USERPROFILE%' } else { '%TEMP%' }
        $text = [regex]::Replace(
            $text,
            [regex]::Escape($literalPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)),
            $replacement,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    return $text
}

function Assert-InstallerReportContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Collections.IDictionary]$Context
    )

    $requiredKeys = @(
        'RunId', 'SourceRevision', 'StartedAt', 'CompletedAt', 'Outcome', 'ExitCode',
        'CompletedPackageCount', 'PlannedPackageCount', 'Duration', 'RestartRequired',
        'CleanupStatus', 'DownloadsRetained', 'RetainedWorkspacePath', 'FailureMessage',
        'ComputerName', 'OperatingSystem', 'Architecture', 'PowerShell', 'CurlVersion',
        'Culture', 'Components', 'DotNetChannels', 'VisualCppVersions', 'ResolvedPackages',
        'SecurityControls', 'UserProfilePath', 'TempPath'
    )
    foreach ($key in $requiredKeys) {
        if (-not $Context.Contains($key)) {
            throw "Technical report context is missing required key: $key"
        }
    }
    if ([string]$Context.Outcome -notin @('Success', 'Restart', 'Failed')) {
        throw "Technical report context contains an invalid outcome: $($Context.Outcome)"
    }
}

function Export-InstallerTechnicalReport {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$DestinationPath = '',

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DefaultDirectory,

        [Parameter(Mandatory = $true)]
        [Collections.IDictionary]$Context,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [psobject[]]$Events,

        [datetime]$Timestamp = [datetime]::Now
    )

    Assert-InstallerReportContext -Context $Context
    $reportPath = Resolve-InstallerReportPath -DestinationPath $DestinationPath -DefaultDirectory $DefaultDirectory -Timestamp $Timestamp
    $reportDirectory = Split-Path -Parent $reportPath
    if (-not (Test-Path -LiteralPath $reportDirectory -PathType Container)) {
        $null = New-Item -Path $reportDirectory -ItemType Directory -Force -ErrorAction Stop
    }

    $lines = New-Object 'Collections.Generic.List[string]'
    $rule = '=' * $script:ConsoleWidth
    $sectionRule = '-' * $script:ConsoleWidth
    $outcomeText = ([string]$Context.Outcome).ToUpperInvariant()
    $restartText = if ([bool]$Context.RestartRequired) { 'Required - restart Windows manually' } else { 'Not required' }
    $retentionText = if ([bool]$Context.DownloadsRetained) { 'Retained' } else { 'Removed unless cleanup failed' }

    $lines.Add('MICROSOFT RUNTIME INSTALLER - TECHNICAL REPORT')
    $lines.Add($rule)
    $lines.Add('Review before external sharing: this report includes a computer name and OS details.')
    $lines.Add('It intentionally excludes credentials, environment-variable dumps, and package contents.')
    $lines.Add('')
    $lines.Add('EXECUTIVE RESULT')
    $lines.Add($sectionRule)
    $lines.Add(('Outcome                  : {0}' -f $outcomeText))
    $lines.Add(('Process exit code        : {0}' -f $Context.ExitCode))
    $lines.Add(('Packages completed       : {0} of {1}' -f $Context.CompletedPackageCount, $Context.PlannedPackageCount))
    $lines.Add(('Elapsed time             : {0}' -f (Format-InstallerDuration -Duration ([timespan]$Context.Duration))))
    $lines.Add(('Restart                  : {0}' -f $restartText))
    $lines.Add(('Cleanup                  : {0}' -f (ConvertTo-InstallerReportText -Value $Context.CleanupStatus -Context $Context)))
    $lines.Add('')
    $lines.Add('RUN IDENTITY')
    $lines.Add($sectionRule)
    $lines.Add('Report schema            : 1')
    $lines.Add(('Run ID                   : {0}' -f (ConvertTo-InstallerReportText -Value $Context.RunId -Context $Context)))
    $lines.Add(('Source revision          : {0}' -f (ConvertTo-InstallerReportText -Value $Context.SourceRevision -Context $Context)))
    $lines.Add(('Started (local)          : {0}' -f ([datetimeoffset]$Context.StartedAt).ToString('o', [Globalization.CultureInfo]::InvariantCulture)))
    $lines.Add(('Completed (local)        : {0}' -f ([datetimeoffset]$Context.CompletedAt).ToString('o', [Globalization.CultureInfo]::InvariantCulture)))
    $lines.Add(('Completed (UTC)          : {0}' -f ([datetimeoffset]$Context.CompletedAt).UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)))
    $lines.Add('')
    $lines.Add('SYSTEM CONTEXT')
    $lines.Add($sectionRule)
    $lines.Add(('Computer name            : {0}' -f (ConvertTo-InstallerReportText -Value $Context.ComputerName -Context $Context)))
    $lines.Add(('Operating system         : {0}' -f (ConvertTo-InstallerReportText -Value $Context.OperatingSystem -Context $Context)))
    $lines.Add(('Target architecture      : {0}' -f (ConvertTo-InstallerReportText -Value $Context.Architecture -Context $Context)))
    $lines.Add(('PowerShell               : {0}' -f (ConvertTo-InstallerReportText -Value $Context.PowerShell -Context $Context)))
    $lines.Add(('curl                     : {0}' -f (ConvertTo-InstallerReportText -Value $Context.CurlVersion -Context $Context)))
    $lines.Add(('Culture                  : {0}' -f (ConvertTo-InstallerReportText -Value $Context.Culture -Context $Context)))
    $lines.Add('Elevated                 : Yes')
    $lines.Add('')
    $lines.Add('REQUESTED AND RESOLVED PLAN')
    $lines.Add($sectionRule)
    $lines.Add(('Components               : {0}' -f (ConvertTo-InstallerReportText -Value $Context.Components -Context $Context)))
    $lines.Add(('.NET channels            : {0}' -f (ConvertTo-InstallerReportText -Value $Context.DotNetChannels -Context $Context)))
    $lines.Add(('Visual C++ families      : {0}' -f (ConvertTo-InstallerReportText -Value $Context.VisualCppVersions -Context $Context)))
    $lines.Add(('Resolved package count   : {0}' -f @($Context.ResolvedPackages).Count))
    if (@($Context.ResolvedPackages).Count -eq 0) {
        $lines.Add('  No package list was resolved before the run stopped.')
    }
    else {
        foreach ($packageLine in @($Context.ResolvedPackages)) {
            $lines.Add(('  {0}' -f (ConvertTo-InstallerReportText -Value $packageLine -Context $Context)))
        }
    }
    $lines.Add('')
    $lines.Add('SECURITY AND CLEANUP')
    $lines.Add($sectionRule)
    foreach ($control in @($Context.SecurityControls)) {
        $lines.Add(('  - {0}' -f (ConvertTo-InstallerReportText -Value $control -Context $Context)))
    }
    $lines.Add(('Download retention       : {0}' -f $retentionText))
    if (-not [string]::IsNullOrWhiteSpace([string]$Context.RetainedWorkspacePath)) {
        $lines.Add(('Retained workspace       : {0}' -f (ConvertTo-InstallerReportText -Value $Context.RetainedWorkspacePath -Context $Context)))
    }
    $lines.Add(('Cleanup result           : {0}' -f (ConvertTo-InstallerReportText -Value $Context.CleanupStatus -Context $Context)))
    $lines.Add('')
    $lines.Add('EVENT TIMELINE')
    $lines.Add($sectionRule)
    if ($Events.Count -eq 0) {
        $lines.Add('No structured diagnostic events were captured.')
    }
    else {
        foreach ($diagnosticEvent in $Events) {
            $eventTimestamp = ([datetimeoffset]$diagnosticEvent.Timestamp).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $eventState = ([string]$diagnosticEvent.State).ToUpperInvariant().PadRight(8)
            $eventMessage = ConvertTo-InstallerReportText -Value $diagnosticEvent.Message -Context $Context
            $lines.Add(('{0} | {1} | {2}' -f $eventTimestamp, $eventState, $eventMessage))
        }
    }
    $lines.Add('')
    $lines.Add('FAILURE ANALYSIS / NEXT ACTIONS')
    $lines.Add($sectionRule)
    if ([string]$Context.Outcome -eq 'Failed') {
        $lines.Add(('Failure reason           : {0}' -f (ConvertTo-InstallerReportText -Value $Context.FailureMessage -Context $Context)))
        $lines.Add('Recommended actions:')
        $lines.Add('  1. Locate the first FAILED event and the package or phase immediately before it.')
        $lines.Add('  2. Confirm network access to the reported Microsoft host and sufficient disk space.')
        $lines.Add('  3. Retry from an Administrator console; attach this report if the failure repeats.')
    }
    elseif ([bool]$Context.RestartRequired) {
        $lines.Add('No installation failure was recorded. Restart Windows manually to finish setup.')
    }
    else {
        $lines.Add('No installation failure or restart requirement was recorded.')
    }
    $lines.Add('')
    $lines.Add($rule)
    $lines.Add('END OF REPORT')

    $encoding = New-Object Text.UTF8Encoding($true)
    $fileStream = New-Object IO.FileStream(
        $reportPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $writer = New-Object IO.StreamWriter($fileStream, $encoding)
        try {
            $writer.Write(($lines -join [Environment]::NewLine) + [Environment]::NewLine)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }

    return $reportPath
}

function Write-InstallerWrappedLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [ConsoleColor]$Color
    )

    $remainingText = $Text.Trim()
    $continuationPrefix = ' ' * $Prefix.Length
    $currentPrefix = $Prefix
    if ($remainingText.Length -eq 0) {
        Write-Host $Prefix -ForegroundColor $Color
        return
    }

    while ($remainingText.Length -gt 0) {
        $availableWidth = $script:ConsoleWidth - $currentPrefix.Length
        if ($availableWidth -lt 1) { $availableWidth = 1 }

        if ($remainingText.Length -le $availableWidth) {
            $lineText = $remainingText
            $remainingText = ''
        }
        else {
            $breakPosition = $remainingText.LastIndexOf(' ', $availableWidth)
            if ($breakPosition -le 0) { $breakPosition = $availableWidth }
            $lineText = $remainingText.Substring(0, $breakPosition).TrimEnd()
            $remainingText = $remainingText.Substring($breakPosition).TrimStart()
        }

        Write-Host ($currentPrefix + $lineText) -ForegroundColor $Color
        $currentPrefix = $continuationPrefix
    }
}

function Write-InstallerBanner {
    [CmdletBinding()]
    param()

    $topRule = '+' + ('-' * ($script:ConsoleWidth - 2)) + '+'
    $contentWidth = $script:ConsoleWidth - 4
    $title = 'MICROSOFT RUNTIME INSTALLER'
    $subtitle = 'SECURE DOWNLOADS | VERIFIED FILES | AUTO CLEANUP'
    $titleLeftPadding = [math]::Floor(($contentWidth - $title.Length) / 2)
    $subtitleLeftPadding = [math]::Floor(($contentWidth - $subtitle.Length) / 2)
    $centeredTitle = ((' ' * $titleLeftPadding) + $title).PadRight($contentWidth)
    $centeredSubtitle = ((' ' * $subtitleLeftPadding) + $subtitle).PadRight($contentWidth)

    Write-Host ''
    Write-Host $topRule -ForegroundColor Cyan
    Write-Host ('| ' + $centeredTitle + ' |') -ForegroundColor Cyan
    Write-Host ('| ' + $centeredSubtitle + ' |') -ForegroundColor Cyan
    Write-Host $topRule -ForegroundColor Cyan
}

function Write-InstallerHelp {
    [CmdletBinding()]
    param()

    Write-InstallerBanner
    Write-Host ''
    Write-Host 'USAGE' -ForegroundColor Cyan
    Write-Host '  powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1 [options]'
    Write-Host '  pwsh.exe -NoProfile -File .\Install.ps1 [options]'
    Write-Host ''
    Write-Host 'Run without selection options to open the interactive package menu.'
    Write-Host 'Explicit selection options bypass the menu for automation.'
    Write-Host ''
    Write-Host 'OPTIONS' -ForegroundColor Cyan
    Write-Host '  -Components <list>          All (default), DotNet, VisualCpp, DirectX'
    Write-Host '  -ExcludeComponents <list>   Remove component groups from the enabled set'
    Write-Host '  -DotNetChannels <list>      All, or supported channels such as 8.0,10.0'
    Write-Host '  -VisualCppVersions <list>   All, 2005, 2008, 2010, 2012, 2013, or v14'
    Write-Host '  -KeepDownloads              Keep the Microsoft installer workspace'
    Write-Host '  -ReportPath <path>          Write a UTF-8 developer/IT .txt report'
    Write-Host '  -h | -Help | --help         Show help without UAC or downloads'
    Write-Host ''
    Write-Host 'RULES' -ForegroundColor Cyan
    Write-Host '  * Separate multiple values with commas. Values are case-insensitive.'
    Write-Host '  * Architecture is automatic and cannot be overridden.'
    Write-Host '  * Explicit .NET channels must still be supported by Microsoft.'
    Write-Host '  * .NET resolves the latest stable SDK in each selected supported channel.'
    Write-Host '  * .NET latest.version is accepted only with Microsoft SHA-512 metadata.'
    Write-Host '  * Visual C++ v14 tracks Microsoft''s latest supported release.'
    Write-Host '  * Legacy Visual C++ and DirectX packages are final fixed releases.'
    Write-Host '  * Fixed packages require reviewed SHA-256 and Microsoft signatures.'
    Write-Host '  * Every Microsoft package source is resolved when the run starts.'
    Write-Host '  * Microsoft progress windows may appear; they require no clicks.'
    Write-Host '  * Packages never restart Windows automatically.'
    Write-Host '  * Downloads are removed by default, including after failures.'
    Write-Host ''
    Write-Host 'EXAMPLES' -ForegroundColor Cyan
    Write-Host '  .\Install.ps1'
    Write-Host '  .\Install.ps1 -Components DotNet,DirectX -DotNetChannels 8.0,10.0'
    Write-Host '  .\Install.ps1 -Components VisualCpp -VisualCppVersions 2013,v14'
    Write-Host '  .\Install.ps1 -ExcludeComponents DirectX -KeepDownloads'
    Write-Host '  .\Install.ps1 -Components DotNet -ReportPath "$env:USERPROFILE"'
    Write-Host ''
    Write-Host 'EXIT CODES' -ForegroundColor Cyan
    Write-Host '  0     Completed successfully'
    Write-Host '  1     Validation, download, verification, installation, or cleanup failed'
    Write-Host '  2     Cancelled from the interactive selector before installation'
    Write-Host '  3010  Completed successfully; restart Windows to finish'
}

function Write-InstallerMenuKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Key
    )

    Write-Host '[' -NoNewline
    Write-Host $Key -ForegroundColor Cyan -NoNewline
    Write-Host ']' -NoNewline
}

function Write-InstallerPackageChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 3)]
        [int]$Key,

        [Parameter(Mandatory = $true)]
        [bool]$Enabled,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Detail
    )

    $stateText = if ($Enabled) { '[ ON ]' } else { '[OFF ]' }
    $stateColor = if ($Enabled) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }

    Write-Host '  ' -NoNewline
    Write-InstallerMenuKey -Key $Key
    Write-Host '  ' -NoNewline
    Write-Host $stateText -ForegroundColor $stateColor -NoNewline
    Write-Host '  ' -NoNewline
    Write-Host $Label
    Write-Host (' ' * 15) -NoNewline
    Write-Host $Detail -ForegroundColor Gray
}

function Write-InstallerSettingChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value,

        [ConsoleColor]$ValueColor = [ConsoleColor]::Cyan
    )

    Write-Host '  ' -NoNewline
    Write-InstallerMenuKey -Key $Key
    Write-Host '  ' -NoNewline
    Write-Host $Label
    Write-InstallerWrappedLine -Prefix '       Current selection: ' -Text $Value -Color $ValueColor
}

function Write-InstallerSelectionMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$SelectedComponents,

        [Parameter(Mandatory = $true)]
        [string]$DotNetChannels,

        [Parameter(Mandatory = $true)]
        [string]$VisualCppVersions,

        [Parameter(Mandatory = $true)]
        [bool]$KeepDownloads,

        [AllowEmptyString()]
        [string]$FeedbackMessage = '',

        [ValidateSet('Info', 'Updated', 'Failed')]
        [string]$FeedbackState = 'Info'
    )

    $selectedCount = @($SelectedComponents.Values | Where-Object { $_ }).Count
    $dotNetDetail = if (-not $SelectedComponents.DotNet) {
        'Unavailable - turn on package 1'
    }
    elseif ($DotNetChannels.Trim() -ieq 'All') {
        'All supported channels'
    }
    else {
        $DotNetChannels
    }
    $visualCppDetail = if (-not $SelectedComponents.VisualCpp) {
        'Unavailable - turn on package 2'
    }
    elseif ($VisualCppVersions.Trim() -ieq 'All') {
        'All release families'
    }
    else {
        $VisualCppVersions
    }
    $dotNetDetailColor = if ($SelectedComponents.DotNet) { [ConsoleColor]::Cyan } else { [ConsoleColor]::Yellow }
    $visualCppDetailColor = if ($SelectedComponents.VisualCpp) { [ConsoleColor]::Cyan } else { [ConsoleColor]::Yellow }
    $keepDetail = if ($KeepDownloads) {
        'Yes - retain files after installation'
    }
    else {
        'No - remove files after installation'
    }
    $keepDetailColor = if ($KeepDownloads) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Green }
    $countColor = if ($selectedCount -gt 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
    $headingText = '  SELECT PACKAGES'
    $countText = '{0} OF 3 SELECTED' -f $selectedCount
    $headingGap = $script:ConsoleWidth - $headingText.Length - $countText.Length

    Write-Host ''
    Write-Host $headingText -ForegroundColor Cyan -NoNewline
    Write-Host (' ' * $headingGap) -NoNewline
    Write-Host $countText -ForegroundColor $countColor
    Write-Host '  Press 1, 2, or 3 to turn a package group on or off.' -ForegroundColor Gray
    Write-Host ''
    Write-InstallerPackageChoice -Key 1 -Enabled ([bool]$SelectedComponents.DotNet) -Label '.NET SDKs' -Detail 'Latest stable SDK in each selected supported channel'
    Write-Host ''
    Write-InstallerPackageChoice -Key 2 -Enabled ([bool]$SelectedComponents.VisualCpp) -Label 'Visual C++ Redistributables' -Detail 'Latest supported v14 plus final 2005-2013 releases'
    Write-Host ''
    Write-InstallerPackageChoice -Key 3 -Enabled ([bool]$SelectedComponents.DirectX) -Label 'DirectX Legacy Runtime' -Detail 'Final June 2010 legacy release'
    Write-Host ''
    Write-Host ''
    Write-Host '  OPTIONAL SETTINGS' -ForegroundColor Cyan
    Write-Host '  Press 4, 5, or K to change a setting.' -ForegroundColor Gray
    Write-Host ''
    Write-InstallerSettingChoice -Key 4 -Label 'Choose .NET SDK channels' -Value $dotNetDetail -ValueColor $dotNetDetailColor
    Write-Host ''
    Write-InstallerSettingChoice -Key 5 -Label 'Choose Visual C++ release families' -Value $visualCppDetail -ValueColor $visualCppDetailColor
    Write-Host ''
    Write-InstallerSettingChoice -Key K -Label 'Keep downloaded installers' -Value $keepDetail -ValueColor $keepDetailColor
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-InstallerMenuKey -Key A
    Write-Host '  Restore all default selections'
    Write-Host ''
    Write-Host ('  ' + ('-' * ($script:ConsoleWidth - 4))) -ForegroundColor Cyan
    $leftAction = '  [ ENTER ]  INSTALL SELECTED PACKAGES'
    $rightAction = '[ Q ]  CANCEL'
    $actionGap = $script:ConsoleWidth - $leftAction.Length - $rightAction.Length
    Write-Host '  [' -NoNewline
    Write-Host ' ENTER ' -ForegroundColor Green -NoNewline
    Write-Host ']  INSTALL SELECTED PACKAGES' -NoNewline
    Write-Host (' ' * $actionGap) -NoNewline
    Write-Host '[' -NoNewline
    Write-Host ' Q ' -ForegroundColor Yellow -NoNewline
    Write-Host ']  CANCEL'
    Write-Host ('  ' + ('-' * ($script:ConsoleWidth - 4))) -ForegroundColor Cyan

    if (-not [string]::IsNullOrWhiteSpace($FeedbackMessage)) {
        Write-Host ''
        $feedbackLabel = 'INFO'
        $feedbackColor = [ConsoleColor]::Cyan
        if ($FeedbackState -eq 'Updated') {
            $feedbackLabel = 'UPDATED'
            $feedbackColor = [ConsoleColor]::Green
        }
        elseif ($FeedbackState -eq 'Failed') {
            $feedbackLabel = 'ERROR'
            $feedbackColor = [ConsoleColor]::Red
        }
        Write-InstallerWrappedLine -Prefix ('  {0}: ' -f $feedbackLabel) -Text $FeedbackMessage -Color $feedbackColor
    }
    Write-Host ''
}

function Test-InstallerMenuSelection {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    if ($Value -notmatch $Pattern) { return $false }
    $tokens = @($Value.Split(','))
    if ($tokens.Count -gt 1 -and $tokens -icontains 'All') { return $false }

    $seen = @{}
    foreach ($token in $tokens) {
        $key = $token.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return $false }
        $seen[$key] = $true
    }
    return $true
}

function Clear-InstallerScreen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScreenClearer
    )

    try {
        $null = & $ScreenClearer
    }
    catch {
        # Clearing is cosmetic. A host without screen-clearing support must not
        # prevent package selection or unattended installation.
        $null = $_
    }
}

function Read-InstallerSelection {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [scriptblock]$InputProvider = { param($Prompt) Read-Host -Prompt $Prompt },

        [scriptblock]$ScreenClearer = { [Console]::Clear() },

        [bool]$InitialKeepDownloads = $false
    )

    $selectedComponents = @{
        DotNet   = $true
        VisualCpp = $true
        DirectX = $true
    }
    $dotNetChannels = 'All'
    $visualCppVersions = 'All'
    $keepDownloads = $InitialKeepDownloads
    $feedbackMessage = ''
    $feedbackState = 'Info'

    while ($true) {
        Clear-InstallerScreen -ScreenClearer $ScreenClearer
        Write-InstallerBanner
        Write-InstallerSelectionMenu -SelectedComponents $selectedComponents -DotNetChannels $dotNetChannels -VisualCppVersions $visualCppVersions -KeepDownloads $keepDownloads -FeedbackMessage $feedbackMessage -FeedbackState $feedbackState
        $rawChoice = & $InputProvider 'Selection'
        if ($null -eq $rawChoice) {
            throw 'Interactive input ended. Use explicit component switches for automation.'
        }
        $choice = ([string]$rawChoice).Trim()

        if ($choice.Length -eq 0) {
            $enabledCount = @($selectedComponents.Values | Where-Object { $_ }).Count
            if ($enabledCount -eq 0) {
                $feedbackMessage = 'Select at least one package group.'
                $feedbackState = 'Failed'
                continue
            }

            $components = @('DotNet', 'VisualCpp', 'DirectX') |
                Where-Object { $selectedComponents[$_] }
            Clear-InstallerScreen -ScreenClearer $ScreenClearer
            return [pscustomobject]@{
                Components        = $components -join ','
                DotNetChannels    = if ($selectedComponents.DotNet) { $dotNetChannels } else { 'All' }
                VisualCppVersions = if ($selectedComponents.VisualCpp) { $visualCppVersions } else { 'All' }
                KeepDownloads     = $keepDownloads
                Cancelled         = $false
            }
        }

        switch ($choice.ToUpperInvariant()) {
            '1' {
                $selectedComponents.DotNet = -not $selectedComponents.DotNet
                $state = if ($selectedComponents.DotNet) { 'ON' } else { 'OFF' }
                $feedbackMessage = ".NET SDKs turned $state."
                $feedbackState = 'Updated'
                continue
            }
            '2' {
                $selectedComponents.VisualCpp = -not $selectedComponents.VisualCpp
                $state = if ($selectedComponents.VisualCpp) { 'ON' } else { 'OFF' }
                $feedbackMessage = "Visual C++ Redistributables turned $state."
                $feedbackState = 'Updated'
                continue
            }
            '3' {
                $selectedComponents.DirectX = -not $selectedComponents.DirectX
                $state = if ($selectedComponents.DirectX) { 'ON' } else { 'OFF' }
                $feedbackMessage = "DirectX Legacy Runtime turned $state."
                $feedbackState = 'Updated'
                continue
            }
            '4' {
                if (-not $selectedComponents.DotNet) {
                    $feedbackMessage = 'Option 4 is unavailable. Turn on package 1 first.'
                    $feedbackState = 'Failed'
                    continue
                }
                $rawChannels = & $InputProvider '.NET SDK channels (All or example: 8.0,10.0)'
                if ($null -eq $rawChannels) {
                    throw 'Interactive input ended while choosing .NET SDK channels.'
                }
                $candidate = ([string]$rawChannels).Trim() -replace '[ \t]', ''
                $channelPattern = '(?i)\A(?:All|\d+\.\d+)(?:,(?:\d+\.\d+))*\z'
                if (-not (Test-InstallerMenuSelection -Value $candidate -Pattern $channelPattern)) {
                    $feedbackMessage = 'Use All or comma-separated SDK channels such as 8.0,10.0.'
                    $feedbackState = 'Failed'
                    continue
                }
                $dotNetChannels = $candidate
                $feedbackMessage = ".NET SDK channels changed to $candidate."
                $feedbackState = 'Updated'
                continue
            }
            '5' {
                if (-not $selectedComponents.VisualCpp) {
                    $feedbackMessage = 'Option 5 is unavailable. Turn on package 2 first.'
                    $feedbackState = 'Failed'
                    continue
                }
                $rawVersions = & $InputProvider 'Visual C++ release families (All or example: 2013,v14)'
                if ($null -eq $rawVersions) {
                    throw 'Interactive input ended while choosing Visual C++ release families.'
                }
                $candidate = ([string]$rawVersions).Trim() -replace '[ \t]', ''
                $versionPattern = '(?i)\A(?:All|2005|2008|2010|2012|2013|v14)(?:,(?:2005|2008|2010|2012|2013|v14))*\z'
                if (-not (Test-InstallerMenuSelection -Value $candidate -Pattern $versionPattern)) {
                    $feedbackMessage = 'Use All or release families from 2005, 2008, 2010, 2012, 2013, and v14.'
                    $feedbackState = 'Failed'
                    continue
                }
                $visualCppVersions = $candidate
                $feedbackMessage = "Visual C++ release families changed to $candidate."
                $feedbackState = 'Updated'
                continue
            }
            'A' {
                $selectedComponents.DotNet = $true
                $selectedComponents.VisualCpp = $true
                $selectedComponents.DirectX = $true
                $dotNetChannels = 'All'
                $visualCppVersions = 'All'
                $feedbackMessage = 'All package groups and version choices restored.'
                $feedbackState = 'Updated'
                continue
            }
            'K' {
                $keepDownloads = -not $keepDownloads
                $feedbackMessage = if ($keepDownloads) {
                    'Downloaded installers will be retained.'
                }
                else {
                    'Downloaded installers will be removed after installation.'
                }
                $feedbackState = 'Updated'
                continue
            }
            'Q' {
                Clear-InstallerScreen -ScreenClearer $ScreenClearer
                Write-InstallerStatus -State Info -Message 'Installation cancelled before elevation or downloads.'
                return [pscustomobject]@{
                    Components        = ''
                    DotNetChannels    = 'All'
                    VisualCppVersions = 'All'
                    KeepDownloads     = $keepDownloads
                    Cancelled         = $true
                }
            }
            default {
                $feedbackMessage = "Unknown selection '$choice'. Choose 1-5, A, K, ENTER, or Q."
                $feedbackState = 'Failed'
            }
        }
    }
}

function Write-InstallerSystemSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [string]$PowerShellVersion,

        [string]$PowerShellEdition = '',

        [Parameter(Mandatory = $true)]
        [string]$CurlVersion,

        [Parameter(Mandatory = $true)]
        [int]$DotNetPackageCount,

        [Parameter(Mandatory = $true)]
        [int]$VisualCppPackageCount,

        [Parameter(Mandatory = $true)]
        [bool]$DirectXSelected,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$FixedHashPackageCount,

        [Parameter(Mandatory = $true)]
        [bool]$RollingVisualCppSelected
    )

    $powerShellDisplay = $PowerShellVersion
    if (-not [string]::IsNullOrWhiteSpace($PowerShellEdition)) {
        $powerShellDisplay = "$PowerShellVersion ($PowerShellEdition)"
    }
    Write-InstallerStatus -State Info -Message "System: Windows $Architecture | PowerShell $powerShellDisplay | curl $CurlVersion"
    Write-InstallerStatus -State Info -Message ("Install plan: {0}" -f (Format-InstallerPlan -DotNetPackageCount $DotNetPackageCount -VisualCppPackageCount $VisualCppPackageCount -DirectXSelected $DirectXSelected))
    $trustControls = @('approved Microsoft HTTPS sources')
    if ($DotNetPackageCount -gt 0) { $trustControls += '.NET SHA-512 hashes' }
    if ($FixedHashPackageCount -gt 0) {
        $trustControls += 'fixed-package SHA-256 hashes'
    }
    if ($VisualCppPackageCount -gt 0 -or $DirectXSelected) {
        $trustControls += 'Microsoft digital signatures'
    }
    if ($RollingVisualCppSelected) { $trustControls += 'v14 version floor' }
    Write-InstallerStatus -State Info -Message ("Security checks: {0}" -f ($trustControls -join ' | '))
    Write-InstallerStatus -State Info -Message 'Temporary files: isolated for this run and removed automatically when finished'
}

function Write-InstallerSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 99)]
        [int]$Number,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 99)]
        [int]$Total,

        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Add-InstallerDiagnosticEvent -State Phase -Message ('Phase {0} of {1}: {2}' -f $Number, $Total, $Title)
    Write-Host ''
    Write-Host ('-' * $script:ConsoleWidth) -ForegroundColor DarkGray
    Write-Host ('  PHASE {0} OF {1}  {2}' -f $Number, $Total, $Title.ToUpperInvariant()) -ForegroundColor Cyan
    Write-Host ('-' * $script:ConsoleWidth) -ForegroundColor DarkGray
}

function Write-InstallerStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Download', 'Verify', 'Install', 'Info', 'Ok', 'Restart', 'Failed', 'Cleanup', 'Retained')]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Add-InstallerDiagnosticEvent -State $State -Message $Message
    $timestamp = [datetime]::Now.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $timestampText = '[{0}] ' -f $timestamp
    $badge = Get-InstallerStatusBadge -State $State
    $prefix = $timestampText + $badge + ' '
    $remainingText = $Message.Trim()
    $continuationPrefix = ' ' * $prefix.Length
    $firstLine = $true
    $messageColor = switch ($State) {
        'Failed' { [ConsoleColor]::Red }
        'Restart' { [ConsoleColor]::Yellow }
        'Retained' { [ConsoleColor]::Yellow }
        default { [ConsoleColor]::Gray }
    }

    if ($remainingText.Length -eq 0) {
        Write-Host $timestampText -ForegroundColor DarkGray -NoNewline
        Write-Host $badge -ForegroundColor (Get-InstallerStatusColor -State $State)
        return
    }

    while ($remainingText.Length -gt 0) {
        $availableWidth = $script:ConsoleWidth - $prefix.Length
        if ($availableWidth -lt 1) { $availableWidth = 1 }
        if ($remainingText.Length -le $availableWidth) {
            $lineText = $remainingText
            $remainingText = ''
        }
        else {
            $breakPosition = $remainingText.LastIndexOf(' ', $availableWidth)
            if ($breakPosition -le 0) { $breakPosition = $availableWidth }
            $lineText = $remainingText.Substring(0, $breakPosition).TrimEnd()
            $remainingText = $remainingText.Substring($breakPosition).TrimStart()
        }

        if ($firstLine) {
            Write-Host $timestampText -ForegroundColor DarkGray -NoNewline
            Write-Host $badge -ForegroundColor (Get-InstallerStatusColor -State $State) -NoNewline
            Write-Host (' ' + $lineText) -ForegroundColor $messageColor
            $firstLine = $false
        }
        else {
            Write-Host ($continuationPrefix + $lineText) -ForegroundColor $messageColor
        }
    }
}

function Write-InstallerCompletionScreen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Restart', 'Failed')]
        [string]$Outcome,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$CompletedPackageCount,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$PlannedPackageCount,

        [Parameter(Mandatory = $true)]
        [timespan]$Duration,

        [Parameter(Mandatory = $true)]
        [bool]$CleanupSucceeded,

        [Parameter(Mandatory = $true)]
        [bool]$RestartRequired,

        [bool]$DownloadsRetained = $false,

        [string]$RetainedWorkspacePath = '',

        [string]$Message = '',

        [string]$ReportPath = ''
    )

    $heading = 'INSTALLATION NEEDS ATTENTION'
    $headingColor = [ConsoleColor]::Red
    $resultText = 'FAILED'
    $resultColor = [ConsoleColor]::Red
    $summaryText = 'The installer stopped before all selected packages completed.'
    if ($Outcome -eq 'Success') {
        $heading = 'INSTALLATION COMPLETED SUCCESSFULLY'
        $headingColor = [ConsoleColor]::Green
        $resultText = 'SUCCESS'
        $resultColor = [ConsoleColor]::Green
        $summaryText = 'All selected Microsoft runtime packages completed successfully.'
    }
    elseif ($Outcome -eq 'Restart') {
        $heading = 'INSTALLATION COMPLETED - RESTART REQUIRED'
        $headingColor = [ConsoleColor]::Yellow
        $resultText = 'SUCCESS - RESTART REQUIRED'
        $resultColor = [ConsoleColor]::Yellow
        $summaryText = 'All selected packages completed successfully.'
    }

    $headingPadding = [math]::Floor(($script:ConsoleWidth - $heading.Length) / 2)
    Write-Host ('=' * $script:ConsoleWidth) -ForegroundColor Cyan
    Write-Host ((' ' * $headingPadding) + $heading) -ForegroundColor $headingColor
    Write-Host ('=' * $script:ConsoleWidth) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  RESULT      ' -NoNewline
    Write-Host $resultText -ForegroundColor $resultColor
    Write-Host ('  PACKAGES    {0} of {1} completed' -f $CompletedPackageCount, $PlannedPackageCount)
    Write-Host ('  ELAPSED     {0}' -f (Format-InstallerDuration -Duration $Duration))
    if ($RestartRequired -and $Outcome -eq 'Failed') {
        Write-Host '  RESTART     A completed package requested a restart.' -ForegroundColor Yellow
    }
    elseif ($RestartRequired) {
        Write-Host '  RESTART     Restart Windows manually to finish setup.' -ForegroundColor Yellow
    }
    elseif ($Outcome -eq 'Failed') {
        Write-Host '  RESTART     No restart was reported before the failure.'
    }
    else {
        Write-Host '  RESTART     No restart is required.'
    }
    if ($DownloadsRetained) {
        Write-InstallerWrappedLine -Prefix '  DOWNLOADS   ' -Text "Downloaded files were kept at: $RetainedWorkspacePath" -Color Yellow
    }
    elseif ($CleanupSucceeded) {
        Write-Host '  DOWNLOADS   Temporary downloads were removed.' -ForegroundColor Green
    }
    else {
        Write-Host '  DOWNLOADS   Temporary download cleanup did not complete.' -ForegroundColor Red
    }
    Write-Host ''
    Write-InstallerWrappedLine -Prefix '  ' -Text $summaryText -Color $headingColor
    if ($Outcome -eq 'Failed') {
        $failureText = if ([string]::IsNullOrWhiteSpace($Message)) { 'No additional failure detail was recorded.' } else { $Message }
        Write-InstallerWrappedLine -Prefix '  ERROR       ' -Text $failureText -Color Red
        Write-Host '  Save the technical report for detailed diagnostics before retrying.' -ForegroundColor Yellow
    }
    elseif ($Outcome -eq 'Restart') {
        Write-Host '  The installer did not restart Windows automatically.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        Write-InstallerWrappedLine -Prefix '  REPORT DIR  ' -Text (Split-Path -Parent $ReportPath) -Color Green
        Write-InstallerWrappedLine -Prefix '  REPORT FILE ' -Text (Split-Path -Leaf $ReportPath) -Color Green
    }
    Write-Host ''
    Write-Host ('=' * $script:ConsoleWidth) -ForegroundColor Cyan
}

function Invoke-InstallerCompletionPrompt {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Restart', 'Failed')]
        [string]$Outcome,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$CompletedPackageCount,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$PlannedPackageCount,

        [Parameter(Mandatory = $true)]
        [timespan]$Duration,

        [Parameter(Mandatory = $true)]
        [bool]$CleanupSucceeded,

        [Parameter(Mandatory = $true)]
        [bool]$RestartRequired,

        [bool]$DownloadsRetained = $false,

        [string]$RetainedWorkspacePath = '',

        [string]$Message = '',

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DefaultReportDirectory,

        [datetime]$Timestamp = [datetime]::Now,

        [scriptblock]$ScreenClearer = { [Console]::Clear() },

        [scriptblock]$KeyProvider = { [Console]::ReadKey($true).KeyChar },

        [scriptblock]$InputProvider = { param($Prompt) Read-Host -Prompt $Prompt },

        [Parameter(Mandatory = $true)]
        [scriptblock]$ReportExporter,

        [string]$ExistingReportPath = '',

        [string]$InitialReportError = ''
    )

    $reportPath = $ExistingReportPath
    $reportSaved = -not [string]::IsNullOrWhiteSpace($reportPath)
    $reportError = $InitialReportError

    while ($true) {
        Clear-InstallerScreen -ScreenClearer $ScreenClearer
        Write-InstallerCompletionScreen -Outcome $Outcome -CompletedPackageCount $CompletedPackageCount -PlannedPackageCount $PlannedPackageCount -Duration $Duration -CleanupSucceeded $CleanupSucceeded -RestartRequired $RestartRequired -DownloadsRetained $DownloadsRetained -RetainedWorkspacePath $RetainedWorkspacePath -Message $Message -ReportPath $reportPath

        if ($reportSaved) {
            Write-Host ''
            Write-Host '  The technical report was saved successfully.' -ForegroundColor Green
            Write-Host '  Press any key to exit when you are ready.' -ForegroundColor Cyan
            $null = & $KeyProvider
            return [pscustomobject]@{
                ReportSaved = $true
                ReportPath  = $reportPath
                ReportError = ''
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($reportError)) {
            Write-Host ''
            Write-InstallerWrappedLine -Prefix '  REPORT ERROR  ' -Text $reportError -Color Red
            Write-Host '  Press R to try again, or press any other key to exit.' -ForegroundColor Yellow
        }
        else {
            Write-Host ''
            Write-Host '  OPTIONAL TECHNICAL REPORT' -ForegroundColor Cyan
            Write-Host '  Save a developer/IT diagnostic report before closing this window.'
            Write-Host ''
            Write-Host '  [ R ]  SAVE TECHNICAL REPORT' -ForegroundColor Green
            Write-Host '  [ ANY OTHER KEY ]  EXIT' -ForegroundColor Cyan
        }

        $keyValue = & $KeyProvider
        $keyText = if ($keyValue -is [ConsoleKeyInfo]) { [string]$keyValue.KeyChar } else { [string]$keyValue }
        if ($keyText -ine 'R') {
            return [pscustomobject]@{
                ReportSaved = $false
                ReportPath  = ''
                ReportError = $reportError
            }
        }

        $defaultReportPath = Resolve-InstallerReportPath -DestinationPath '' -DefaultDirectory $DefaultReportDirectory -Timestamp $Timestamp
        Write-Host ''
        Write-Host '  Enter a folder or a complete .txt filename.' -ForegroundColor Cyan
        Write-InstallerWrappedLine -Prefix '  FOLDER      ' -Text (Split-Path -Parent $defaultReportPath) -Color Gray
        Write-InstallerWrappedLine -Prefix '  FILE        ' -Text (Split-Path -Leaf $defaultReportPath) -Color Gray
        $requestedPath = & $InputProvider 'Report path (press ENTER for the default)'
        if ($null -eq $requestedPath -or [string]::IsNullOrWhiteSpace([string]$requestedPath)) {
            $requestedPath = $defaultReportPath
        }

        try {
            $resolvedPath = Resolve-InstallerReportPath -DestinationPath ([string]$requestedPath) -DefaultDirectory $DefaultReportDirectory -Timestamp $Timestamp
            $reportPath = [string](& $ReportExporter $resolvedPath)
            if ([string]::IsNullOrWhiteSpace($reportPath) -or -not [IO.Path]::IsPathRooted($reportPath)) {
                throw 'The report exporter did not return a complete report path.'
            }
            $reportSaved = $true
            $reportError = ''
        }
        catch {
            $reportSaved = $false
            $reportPath = ''
            $reportError = $_.Exception.Message
        }
    }
}

function Write-InstallerSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Restart', 'Failed')]
        [string]$Outcome,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$CompletedPackageCount,

        [Parameter(Mandatory = $true)]
        [timespan]$Duration,

        [Parameter(Mandatory = $true)]
        [bool]$CleanupSucceeded,

        [string]$RetainedWorkspacePath = '',

        [string]$Message = ''
    )

    Write-Host ''
    Write-Host ('=' * $script:ConsoleWidth) -ForegroundColor Cyan
    switch ($Outcome) {
        'Success' {
            Write-InstallerStatus -State Ok -Message 'Installation completed successfully.'
        }
        'Restart' {
            Write-InstallerStatus -State Restart -Message 'Installation completed successfully. Restart Windows to finish.'
        }
        'Failed' {
            Write-InstallerStatus -State Failed -Message "Installation stopped: $Message"
        }
    }

    Write-InstallerStatus -State Info -Message ("Packages completed: {0} | Elapsed: {1}" -f $CompletedPackageCount, (Format-InstallerDuration -Duration $Duration))
    if (-not [string]::IsNullOrWhiteSpace($RetainedWorkspacePath)) {
        if ($Outcome -eq 'Failed') {
            Write-InstallerStatus -State Retained -Message "Installer workspace retained for diagnosis at: $RetainedWorkspacePath"
        }
        else {
            Write-InstallerStatus -State Retained -Message "Installer workspace retained at: $RetainedWorkspacePath"
        }
    }
    elseif ($CleanupSucceeded) {
        Write-InstallerStatus -State Cleanup -Message 'Temporary download files were removed.'
    }
    else {
        Write-InstallerStatus -State Failed -Message 'Temporary download cleanup did not complete; review the error above.'
    }
    Write-Host ('=' * $script:ConsoleWidth) -ForegroundColor Cyan
}

Export-ModuleMember -Function @(
    'Format-InstallerByteSize',
    'Format-InstallerDuration',
    'Format-InstallerPlan',
    'Export-InstallerTechnicalReport',
    'Get-InstallerDiagnosticEvent',
    'Get-InstallerStatusBadge',
    'Invoke-InstallerCompletionPrompt',
    'Read-InstallerSelection',
    'Initialize-InstallerDiagnostic',
    'Resolve-InstallerReportPath',
    'Write-InstallerBanner',
    'Write-InstallerCompletionScreen',
    'Write-InstallerHelp',
    'Write-InstallerSection',
    'Write-InstallerStatus',
    'Write-InstallerSummary',
    'Write-InstallerSystemSummary'
)
