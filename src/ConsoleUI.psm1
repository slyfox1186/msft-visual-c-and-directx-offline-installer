Set-StrictMode -Version 2.0

$script:DefaultConsoleWidth = 78
$script:MinimumConsoleWidth = 72
$script:MaximumConsoleWidth = 110
$script:StatusBadgeWidth = 8
$script:DiagnosticRunId = ''
$script:DiagnosticEvents = New-Object 'Collections.Generic.List[object]'

# ---------------------------------------------------------------------------
# Shared visual system
#
# Every screen is drawn from the constants below so layout is computed instead
# of hand-padded, and so one color keeps one meaning across the banner, the
# selector, the run log, and the final screens. All output stays inside ASCII
# 0x20-0x7E and uses only standard ConsoleColor values.
# ---------------------------------------------------------------------------

# Left margin shared by every non-log line.
$script:ContentIndent = 2

# Gap between any two aligned columns.
$script:ColumnGap = 2

# Rule vocabulary. '=' closes a top-level screen; '-' separates a section of
# the run log or a group inside a screen. Group rules are inset by the content
# indent so nesting reads without any extra glyphs.
$script:ScreenRuleCharacter = '='
$script:SectionRuleCharacter = '-'

# Selector grid: "  [1]  ON   Label" with the detail line under the label.
$script:MenuKeyWidth = 3
$script:MenuStateWidth = 3
$script:MenuTextColumn = $script:ContentIndent + $script:MenuKeyWidth + $script:ColumnGap + $script:MenuStateWidth + $script:ColumnGap

# Label column for label/value rows on the system, completion, and report
# screens. Derived from the longest label actually rendered so the column never
# has to be counted by hand and cannot drift when wording changes.
$script:DetailLabels = @(
    'RESULT', 'PACKAGES', 'ELAPSED', 'RESTART', 'DOWNLOADS', 'ERROR',
    'REPORT DIR', 'REPORT FILE', 'REPORT ERROR', 'FOLDER', 'FILE',
    'INFO', 'UPDATED'
)
# Windows PowerShell 5.1 returns Measure-Object -Maximum as a nullable double,
# which would make every column width a double. Widen the longest label with an
# explicit integer loop so PadRight always receives an int.
$script:DetailLabelWidth = 0
foreach ($detailLabel in $script:DetailLabels) {
    if ($detailLabel.Length -gt $script:DetailLabelWidth) {
        $script:DetailLabelWidth = $detailLabel.Length
    }
}
$script:DetailLabelWidth += $script:ColumnGap

# Semantic palette. Accent marks structure, title marks the one value that
# matters most on a screen, muted marks subordinate chrome, and the three state
# colors never mean anything other than success, attention, and failure.
$script:AccentColor = [ConsoleColor]::Cyan
$script:TitleColor = [ConsoleColor]::White
$script:BodyColor = [ConsoleColor]::Gray
$script:MutedColor = [ConsoleColor]::DarkGray
$script:SuccessColor = [ConsoleColor]::Green
$script:WarningColor = [ConsoleColor]::Yellow
$script:FailureColor = [ConsoleColor]::Red

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

    # Badge colors carry the same meaning as every other screen: green is a
    # completed step, yellow needs attention, red failed, muted is background
    # bookkeeping, and accent marks the work that is currently running.
    switch ($State) {
        'Ok' { return $script:SuccessColor }
        'Restart' { return $script:WarningColor }
        'Retained' { return $script:WarningColor }
        'Failed' { return $script:FailureColor }
        'Cleanup' { return $script:MutedColor }
        'Info' { return $script:MutedColor }
        default { return $script:AccentColor }
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

function Get-InstallerRepeatedText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateLength(1, 1)]
        [string]$Character,

        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    # Every width in this module is computed from the live console width, so a
    # narrow console can legitimately produce a non-positive count. Clamp here
    # rather than let the string multiplication operator throw.
    if ($Count -lt 1) { return '' }
    return $Character * $Count
}

function Get-InstallerPadding {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    return Get-InstallerRepeatedText -Character ' ' -Count $Count
}

function Get-InstallerRuleText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Screen', 'Section', 'Group')]
        [string]$Level
    )

    if ($Level -eq 'Group') {
        return (Get-InstallerPadding -Count $script:ContentIndent) +
            (Get-InstallerRepeatedText -Character $script:SectionRuleCharacter -Count ($script:ConsoleWidth - (2 * $script:ContentIndent)))
    }

    $character = $script:SectionRuleCharacter
    if ($Level -eq 'Screen') { $character = $script:ScreenRuleCharacter }
    return Get-InstallerRepeatedText -Character $character -Count $script:ConsoleWidth
}

function Write-InstallerRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Screen', 'Section', 'Group')]
        [string]$Level
    )

    $color = $script:MutedColor
    if ($Level -eq 'Screen') { $color = $script:AccentColor }
    Write-Host (Get-InstallerRuleText -Level $Level) -ForegroundColor $color
}

function Write-InstallerBlankLine {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 4)]
        [int]$Count = 1
    )

    # One blank line separates groups inside a screen; the rest of the vertical
    # rhythm comes from rules, so no caller needs an ad hoc empty Write-Host.
    for ($index = 0; $index -lt $Count; $index++) {
        Write-Host ''
    }
}

function Write-InstallerWrappedLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [ConsoleColor]$Color,

        [ConsoleColor]$PrefixColor = [ConsoleColor]::Gray
    )

    # The prefix doubles as the hanging indent: continuation lines are padded to
    # the same width so every wrapped label/value pair stays in one column.
    $effectivePrefixColor = $Color
    if ($PSBoundParameters.ContainsKey('PrefixColor')) { $effectivePrefixColor = $PrefixColor }

    $remainingText = $Text.Trim()
    $continuationPrefix = Get-InstallerPadding -Count $Prefix.Length
    if ($remainingText.Length -eq 0) {
        Write-Host $Prefix -ForegroundColor $effectivePrefixColor
        return
    }

    $firstLine = $true
    while ($remainingText.Length -gt 0) {
        $availableWidth = $script:ConsoleWidth - $Prefix.Length
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
            Write-Host $Prefix -NoNewline -ForegroundColor $effectivePrefixColor
            $firstLine = $false
        }
        else {
            Write-Host $continuationPrefix -NoNewline
        }
        Write-Host $lineText -ForegroundColor $Color
    }
}

function Write-InstallerBodyLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-InstallerWrappedLine -Prefix (Get-InstallerPadding -Count $script:ContentIndent) -Text $Text -Color $Color
}

function Write-InstallerBulletLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Text,

        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    $prefix = (Get-InstallerPadding -Count $script:ContentIndent) + '* '
    Write-InstallerWrappedLine -Prefix $prefix -Text $Text -Color $Color -PrefixColor $script:MutedColor
}

function Write-InstallerDetailLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value,

        [ConsoleColor]$ValueColor = [ConsoleColor]::Gray,

        [ConsoleColor]$LabelColor = [ConsoleColor]::DarkGray
    )

    $labelWidth = [math]::Max($script:DetailLabelWidth, ($Label.Length + $script:ColumnGap))
    $prefix = (Get-InstallerPadding -Count $script:ContentIndent) + $Label.PadRight($labelWidth)
    Write-InstallerWrappedLine -Prefix $prefix -Text $Value -Color $ValueColor -PrefixColor $LabelColor
}

function Write-InstallerDefinitionLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Term,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Description,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 110)]
        [int]$TermWidth,

        [ConsoleColor]$TermColor = [ConsoleColor]::Cyan,

        [ConsoleColor]$DescriptionColor = [ConsoleColor]::Gray
    )

    $width = [math]::Max($TermWidth, ($Term.Length + $script:ColumnGap))
    $prefix = (Get-InstallerPadding -Count $script:ContentIndent) + $Term.PadRight($width)
    Write-InstallerWrappedLine -Prefix $prefix -Text $Description -Color $DescriptionColor -PrefixColor $TermColor
}

function Get-InstallerTermColumnWidth {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Term
    )

    $longest = 0
    foreach ($item in $Term) {
        if ($item.Length -gt $longest) { $longest = $item.Length }
    }
    return $longest + $script:ColumnGap
}

function Write-InstallerHeading {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [ConsoleColor]$TitleColor = [ConsoleColor]::Cyan,

        [AllowEmptyString()]
        [string]$Status = '',

        [ConsoleColor]$StatusColor = [ConsoleColor]::Gray
    )

    # One heading shape for the whole application: title on the left, optional
    # state on the right. The pair drops to two lines rather than overflow when
    # the console is too narrow to hold both, and the title itself wraps on the
    # content indent so no caller-supplied heading can run past the width.
    $indent = Get-InstallerPadding -Count $script:ContentIndent
    if ([string]::IsNullOrEmpty($Status)) {
        Write-InstallerWrappedLine -Prefix $indent -Text $Title -Color $TitleColor
        return
    }

    $gap = $script:ConsoleWidth - $script:ContentIndent - $Title.Length - $Status.Length
    if ($gap -lt $script:ColumnGap) {
        Write-InstallerWrappedLine -Prefix $indent -Text $Title -Color $TitleColor
        if (($script:ContentIndent + $Status.Length) -gt $script:ConsoleWidth) {
            Write-InstallerWrappedLine -Prefix $indent -Text $Status -Color $StatusColor
            return
        }
        Write-Host ((Get-InstallerPadding -Count ($script:ConsoleWidth - $Status.Length)) + $Status) -ForegroundColor $StatusColor
        return
    }

    Write-Host ($indent + $Title) -NoNewline -ForegroundColor $TitleColor
    Write-Host (Get-InstallerPadding -Count $gap) -NoNewline
    Write-Host $Status -ForegroundColor $StatusColor
}

function Write-InstallerSectionHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [AllowEmptyString()]
        [string]$Status = ''
    )

    Write-InstallerBlankLine
    Write-InstallerRule -Level Section
    Write-InstallerHeading -Title $Title -TitleColor $script:TitleColor -Status $Status -StatusColor $script:AccentColor
    Write-InstallerRule -Level Section
}

function Write-InstallerMenuKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        [ConsoleColor]$KeyColor = [ConsoleColor]::Cyan
    )

    # Square brackets mean exactly one thing everywhere in this UI: press this.
    Write-Host '[' -NoNewline -ForegroundColor $script:MutedColor
    Write-Host $Key -NoNewline -ForegroundColor $KeyColor
    Write-Host ']' -NoNewline -ForegroundColor $script:MutedColor
}

function Write-InstallerMenuRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [ConsoleColor]$StateColor,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Label,

        [ConsoleColor]$LabelColor = [ConsoleColor]::Gray
    )

    Write-Host (Get-InstallerPadding -Count $script:ContentIndent) -NoNewline
    Write-InstallerMenuKey -Key $Key
    Write-Host (Get-InstallerPadding -Count ($script:MenuKeyWidth - ($Key.Length + 2))) -NoNewline
    Write-Host (Get-InstallerPadding -Count $script:ColumnGap) -NoNewline
    Write-Host $State.PadRight($script:MenuStateWidth) -NoNewline -ForegroundColor $StateColor
    Write-Host (Get-InstallerPadding -Count $script:ColumnGap) -NoNewline
    Write-Host $Label -ForegroundColor $LabelColor
}

function Write-InstallerMenuDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [ConsoleColor]$Color = [ConsoleColor]::DarkGray,

        [AllowEmptyString()]
        [string]$Label = ''
    )

    $prefix = (Get-InstallerPadding -Count $script:MenuTextColumn) + $Label
    Write-InstallerWrappedLine -Prefix $prefix -Text $Text -Color $Color -PrefixColor $script:MutedColor
}

function Write-InstallerActionBar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PrimaryKey,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PrimaryText,

        [ConsoleColor]$PrimaryKeyColor = [ConsoleColor]::Green,

        [AllowEmptyString()]
        [string]$SecondaryKey = '',

        [AllowEmptyString()]
        [string]$SecondaryText = '',

        [ConsoleColor]$SecondaryKeyColor = [ConsoleColor]::Yellow
    )

    # The primary action is written in the title color so the eye lands on it
    # before the secondary action, which stays in body color on the right.
    $gapText = Get-InstallerPadding -Count $script:ColumnGap
    $indent = Get-InstallerPadding -Count $script:ContentIndent
    $primaryLength = $PrimaryKey.Length + 2 + $script:ColumnGap + $PrimaryText.Length
    $hasSecondary = (-not [string]::IsNullOrEmpty($SecondaryKey)) -and (-not [string]::IsNullOrEmpty($SecondaryText))

    Write-Host $indent -NoNewline
    Write-InstallerMenuKey -Key $PrimaryKey -KeyColor $PrimaryKeyColor
    if (-not $hasSecondary) {
        Write-Host ($gapText + $PrimaryText) -ForegroundColor $script:TitleColor
        return
    }

    $secondaryLength = $SecondaryKey.Length + 2 + $script:ColumnGap + $SecondaryText.Length
    $gap = $script:ConsoleWidth - $script:ContentIndent - $primaryLength - $secondaryLength
    if ($gap -lt $script:ColumnGap) {
        Write-Host ($gapText + $PrimaryText) -ForegroundColor $script:TitleColor
        Write-Host $indent -NoNewline
        Write-InstallerMenuKey -Key $SecondaryKey -KeyColor $SecondaryKeyColor
        Write-Host ($gapText + $SecondaryText) -ForegroundColor $script:BodyColor
        return
    }

    Write-Host ($gapText + $PrimaryText) -NoNewline -ForegroundColor $script:TitleColor
    Write-Host (Get-InstallerPadding -Count $gap) -NoNewline
    Write-InstallerMenuKey -Key $SecondaryKey -KeyColor $SecondaryKeyColor
    Write-Host ($gapText + $SecondaryText) -ForegroundColor $script:BodyColor
}

function Write-InstallerBanner {
    [CmdletBinding()]
    param()

    Write-InstallerBlankLine
    Write-InstallerRule -Level Screen
    Write-InstallerHeading -Title 'MICROSOFT RUNTIME INSTALLER' -TitleColor $script:TitleColor
    Write-InstallerHeading -Title 'SECURE DOWNLOADS | VERIFIED FILES | AUTO CLEANUP' -TitleColor $script:MutedColor
    Write-InstallerRule -Level Screen
}

function Write-InstallerHelp {
    [CmdletBinding()]
    param()

    $options = @(
        @{ Term = '-Components <list>'; Text = 'All (default), DotNet, VisualCpp, DirectX' },
        @{ Term = '-ExcludeComponents <list>'; Text = 'Remove component groups from the enabled set' },
        @{ Term = '-DotNetChannels <list>'; Text = 'All, or supported channels such as 8.0,10.0' },
        @{ Term = '-VisualCppVersions <list>'; Text = 'All, 2005, 2008, 2010, 2012, 2013, or v14' },
        @{ Term = '-KeepDownloads'; Text = 'Keep the Microsoft installer workspace' },
        @{ Term = '-ReportPath <path>'; Text = 'Write a UTF-8 developer/IT .txt report' },
        @{ Term = '-h | -Help | --help'; Text = 'Show help without UAC or downloads' }
    )
    $rules = @(
        'Separate multiple values with commas. Values are case-insensitive.',
        'Architecture is automatic and cannot be overridden.',
        'Explicit .NET channels must still be supported by Microsoft.',
        '.NET resolves the latest stable SDK in each selected supported channel.',
        '.NET latest.version is accepted only with Microsoft SHA-512 metadata.',
        'Visual C++ v14 tracks Microsoft''s latest supported release.',
        'Legacy Visual C++ and DirectX packages are final fixed releases.',
        'Fixed packages require reviewed SHA-256 and Microsoft signatures.',
        'Every Microsoft package source is resolved when the run starts.',
        'Microsoft progress windows may appear; they require no clicks.',
        'Packages never restart Windows automatically.',
        'Downloads are removed by default, including after failures.'
    )
    $examples = @(
        '.\Install.ps1',
        '.\Install.ps1 -Components DotNet,DirectX -DotNetChannels 8.0,10.0',
        '.\Install.ps1 -Components VisualCpp -VisualCppVersions 2013,v14',
        '.\Install.ps1 -ExcludeComponents DirectX -KeepDownloads',
        '.\Install.ps1 -Components DotNet -ReportPath "$env:USERPROFILE"'
    )
    $exitCodes = @(
        @{ Term = '0'; Text = 'Completed successfully' },
        @{ Term = '1'; Text = 'Validation, download, verification, installation, or cleanup failed' },
        @{ Term = '2'; Text = 'Cancelled from the interactive selector before installation' },
        @{ Term = '3010'; Text = 'Completed successfully; restart Windows to finish' }
    )
    $optionWidth = Get-InstallerTermColumnWidth -Term @($options | ForEach-Object { [string]$_.Term })
    $exitCodeWidth = Get-InstallerTermColumnWidth -Term @($exitCodes | ForEach-Object { [string]$_.Term })

    Write-InstallerBanner
    Write-InstallerBlankLine
    Write-InstallerHeading -Title 'USAGE' -TitleColor $script:AccentColor
    Write-InstallerRule -Level Group
    Write-InstallerBodyLine -Text 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1 [options]'
    Write-InstallerBodyLine -Text 'pwsh.exe -NoProfile -File .\Install.ps1 [options]'
    Write-InstallerBlankLine
    Write-InstallerBodyLine -Text 'Run without selection options to open the interactive package menu.' -Color $script:MutedColor
    Write-InstallerBodyLine -Text 'Explicit selection options bypass the menu for automation.' -Color $script:MutedColor

    Write-InstallerBlankLine
    Write-InstallerHeading -Title 'OPTIONS' -TitleColor $script:AccentColor
    Write-InstallerRule -Level Group
    foreach ($option in $options) {
        Write-InstallerDefinitionLine -Term ([string]$option.Term) -Description ([string]$option.Text) -TermWidth $optionWidth -TermColor $script:TitleColor
    }

    Write-InstallerBlankLine
    Write-InstallerHeading -Title 'RULES' -TitleColor $script:AccentColor
    Write-InstallerRule -Level Group
    foreach ($rule in $rules) {
        Write-InstallerBulletLine -Text $rule
    }

    Write-InstallerBlankLine
    Write-InstallerHeading -Title 'EXAMPLES' -TitleColor $script:AccentColor
    Write-InstallerRule -Level Group
    foreach ($example in $examples) {
        Write-InstallerBodyLine -Text $example -Color $script:TitleColor
    }

    Write-InstallerBlankLine
    Write-InstallerHeading -Title 'EXIT CODES' -TitleColor $script:AccentColor
    Write-InstallerRule -Level Group
    foreach ($exitCode in $exitCodes) {
        Write-InstallerDefinitionLine -Term ([string]$exitCode.Term) -Description ([string]$exitCode.Text) -TermWidth $exitCodeWidth -TermColor $script:TitleColor
    }
    Write-InstallerBlankLine
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

    $stateText = 'OFF'
    $stateColor = $script:MutedColor
    $labelColor = $script:BodyColor
    if ($Enabled) {
        $stateText = 'ON'
        $stateColor = $script:SuccessColor
        $labelColor = $script:TitleColor
    }

    Write-InstallerMenuRow -Key ([string]$Key) -State $stateText -StateColor $stateColor -Label $Label -LabelColor $labelColor
    Write-InstallerMenuDetail -Text $Detail
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

        [ConsoleColor]$ValueColor = [ConsoleColor]::White
    )

    # Settings share the package grid but leave the on/off column empty, which
    # is what marks them as choices rather than toggles.
    Write-InstallerMenuRow -Key $Key -State '' -StateColor $script:BodyColor -Label $Label -LabelColor $script:BodyColor
    Write-InstallerMenuDetail -Text $Value -Color $ValueColor -Label 'Current selection: '
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
    $dotNetDetailColor = if ($SelectedComponents.DotNet) { $script:TitleColor } else { $script:WarningColor }
    $visualCppDetailColor = if ($SelectedComponents.VisualCpp) { $script:TitleColor } else { $script:WarningColor }
    $keepDetail = if ($KeepDownloads) {
        'Yes - retain files after installation'
    }
    else {
        'No - remove files after installation'
    }
    $keepDetailColor = if ($KeepDownloads) { $script:WarningColor } else { $script:SuccessColor }
    $countColor = if ($selectedCount -gt 0) { $script:SuccessColor } else { $script:FailureColor }

    Write-InstallerBlankLine
    Write-InstallerHeading -Title 'SELECT PACKAGES' -TitleColor $script:AccentColor -Status ('{0} OF 3 SELECTED' -f $selectedCount) -StatusColor $countColor
    Write-InstallerRule -Level Group
    Write-InstallerBodyLine -Text 'Press 1, 2, or 3 to turn a package group on or off.' -Color $script:MutedColor
    Write-InstallerBlankLine
    Write-InstallerPackageChoice -Key 1 -Enabled ([bool]$SelectedComponents.DotNet) -Label '.NET SDKs' -Detail 'Latest stable SDK in each selected supported channel'
    Write-InstallerPackageChoice -Key 2 -Enabled ([bool]$SelectedComponents.VisualCpp) -Label 'Visual C++ Redistributables' -Detail 'Latest supported v14 plus final 2005-2013 releases'
    Write-InstallerPackageChoice -Key 3 -Enabled ([bool]$SelectedComponents.DirectX) -Label 'DirectX Legacy Runtime' -Detail 'Final June 2010 legacy release'

    Write-InstallerBlankLine
    Write-InstallerHeading -Title 'OPTIONAL SETTINGS' -TitleColor $script:AccentColor
    Write-InstallerRule -Level Group
    Write-InstallerBodyLine -Text 'Press 4, 5, or K to change a setting.' -Color $script:MutedColor
    Write-InstallerBlankLine
    Write-InstallerSettingChoice -Key 4 -Label 'Choose .NET SDK channels' -Value $dotNetDetail -ValueColor $dotNetDetailColor
    Write-InstallerSettingChoice -Key 5 -Label 'Choose Visual C++ release families' -Value $visualCppDetail -ValueColor $visualCppDetailColor
    Write-InstallerSettingChoice -Key K -Label 'Keep downloaded installers' -Value $keepDetail -ValueColor $keepDetailColor
    Write-InstallerMenuRow -Key 'A' -State '' -StateColor $script:BodyColor -Label 'Restore all default selections' -LabelColor $script:BodyColor

    Write-InstallerBlankLine
    Write-InstallerRule -Level Group
    Write-InstallerActionBar -PrimaryKey 'ENTER' -PrimaryText 'INSTALL SELECTED PACKAGES' -PrimaryKeyColor $script:SuccessColor -SecondaryKey 'Q' -SecondaryText 'CANCEL' -SecondaryKeyColor $script:WarningColor
    Write-InstallerRule -Level Group

    if (-not [string]::IsNullOrWhiteSpace($FeedbackMessage)) {
        Write-InstallerBlankLine
        $feedbackLabel = 'INFO'
        $feedbackColor = $script:AccentColor
        if ($FeedbackState -eq 'Updated') {
            $feedbackLabel = 'UPDATED'
            $feedbackColor = $script:SuccessColor
        }
        elseif ($FeedbackState -eq 'Failed') {
            $feedbackLabel = 'ERROR'
            $feedbackColor = $script:FailureColor
        }
        Write-InstallerDetailLine -Label $feedbackLabel -Value $FeedbackMessage -ValueColor $feedbackColor -LabelColor $feedbackColor
    }
    Write-InstallerBlankLine
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
    $trustControls = @('approved Microsoft HTTPS sources')
    if ($DotNetPackageCount -gt 0) { $trustControls += '.NET SHA-512 hashes' }
    if ($FixedHashPackageCount -gt 0) {
        $trustControls += 'fixed-package SHA-256 hashes'
    }
    if ($VisualCppPackageCount -gt 0 -or $DirectXSelected) {
        $trustControls += 'Microsoft digital signatures'
    }
    if ($RollingVisualCppSelected) { $trustControls += 'v14 version floor' }

    # The four lines below stay status events so the technical report keeps
    # recording them verbatim; only the section header around them is chrome.
    Write-InstallerSectionHeader -Title 'SYSTEM AND PLAN'
    Write-InstallerStatus -State Info -Message "System: Windows $Architecture | PowerShell $powerShellDisplay | curl $CurlVersion"
    Write-InstallerStatus -State Info -Message ("Install plan: {0}" -f (Format-InstallerPlan -DotNetPackageCount $DotNetPackageCount -VisualCppPackageCount $VisualCppPackageCount -DirectXSelected $DirectXSelected))
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
    Write-InstallerSectionHeader -Title $Title.ToUpperInvariant() -Status ('PHASE {0} OF {1}' -f $Number, $Total)
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
    $continuationPrefix = Get-InstallerPadding -Count $prefix.Length
    $firstLine = $true
    $messageColor = switch ($State) {
        'Failed' { $script:FailureColor }
        'Restart' { $script:WarningColor }
        'Retained' { $script:WarningColor }
        default { $script:BodyColor }
    }

    if ($remainingText.Length -eq 0) {
        Write-Host $timestampText -ForegroundColor $script:MutedColor -NoNewline
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
            Write-Host $timestampText -ForegroundColor $script:MutedColor -NoNewline
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
    $headingColor = $script:FailureColor
    $resultText = 'FAILED'
    $resultColor = $script:FailureColor
    $summaryText = 'The installer stopped before all selected packages completed.'
    if ($Outcome -eq 'Success') {
        $heading = 'INSTALLATION COMPLETED SUCCESSFULLY'
        $headingColor = $script:SuccessColor
        $resultText = 'SUCCESS'
        $resultColor = $script:SuccessColor
        $summaryText = 'All selected Microsoft runtime packages completed successfully.'
    }
    elseif ($Outcome -eq 'Restart') {
        $heading = 'INSTALLATION COMPLETED - RESTART REQUIRED'
        $headingColor = $script:WarningColor
        $resultText = 'SUCCESS - RESTART REQUIRED'
        $resultColor = $script:WarningColor
        $summaryText = 'All selected packages completed successfully.'
    }

    # The verdict is the heading, repeated as the first label/value row so the
    # screen reads the same whether it is skimmed or pasted into a bug report.
    Write-InstallerRule -Level Screen
    Write-InstallerHeading -Title $heading -TitleColor $headingColor
    Write-InstallerRule -Level Screen
    Write-InstallerBlankLine

    Write-InstallerDetailLine -Label 'RESULT' -Value $resultText -ValueColor $resultColor
    Write-InstallerDetailLine -Label 'PACKAGES' -Value ('{0} of {1} completed' -f $CompletedPackageCount, $PlannedPackageCount)
    Write-InstallerDetailLine -Label 'ELAPSED' -Value (Format-InstallerDuration -Duration $Duration)
    if ($RestartRequired -and $Outcome -eq 'Failed') {
        Write-InstallerDetailLine -Label 'RESTART' -Value 'A completed package requested a restart.' -ValueColor $script:WarningColor
    }
    elseif ($RestartRequired) {
        Write-InstallerDetailLine -Label 'RESTART' -Value 'Restart Windows manually to finish setup.' -ValueColor $script:WarningColor
    }
    elseif ($Outcome -eq 'Failed') {
        Write-InstallerDetailLine -Label 'RESTART' -Value 'No restart was reported before the failure.'
    }
    else {
        Write-InstallerDetailLine -Label 'RESTART' -Value 'No restart is required.'
    }
    if ($DownloadsRetained) {
        Write-InstallerDetailLine -Label 'DOWNLOADS' -Value "Downloaded files were kept at: $RetainedWorkspacePath" -ValueColor $script:WarningColor
    }
    elseif ($CleanupSucceeded) {
        Write-InstallerDetailLine -Label 'DOWNLOADS' -Value 'Temporary downloads were removed.' -ValueColor $script:SuccessColor
    }
    else {
        Write-InstallerDetailLine -Label 'DOWNLOADS' -Value 'Temporary download cleanup did not complete.' -ValueColor $script:FailureColor
    }
    if ($Outcome -eq 'Failed') {
        $failureText = if ([string]::IsNullOrWhiteSpace($Message)) { 'No additional failure detail was recorded.' } else { $Message }
        Write-InstallerDetailLine -Label 'ERROR' -Value $failureText -ValueColor $script:FailureColor -LabelColor $script:FailureColor
    }
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        Write-InstallerDetailLine -Label 'REPORT DIR' -Value (Split-Path -Parent $ReportPath) -ValueColor $script:SuccessColor
        Write-InstallerDetailLine -Label 'REPORT FILE' -Value (Split-Path -Leaf $ReportPath) -ValueColor $script:SuccessColor
    }

    Write-InstallerBlankLine
    Write-InstallerRule -Level Group
    Write-InstallerBodyLine -Text $summaryText -Color $headingColor
    if ($Outcome -eq 'Failed') {
        Write-InstallerBodyLine -Text 'Save the technical report for detailed diagnostics before retrying.' -Color $script:WarningColor
    }
    elseif ($Outcome -eq 'Restart') {
        Write-InstallerBodyLine -Text 'The installer did not restart Windows automatically.'
    }
    Write-InstallerRule -Level Screen
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
            Write-InstallerBlankLine
            Write-InstallerHeading -Title 'TECHNICAL REPORT' -TitleColor $script:AccentColor
            Write-InstallerRule -Level Group
            Write-InstallerBodyLine -Text 'The technical report was saved successfully.' -Color $script:SuccessColor
            Write-InstallerBlankLine
            Write-InstallerActionBar -PrimaryKey 'ANY KEY' -PrimaryText 'EXIT WHEN YOU ARE READY' -PrimaryKeyColor $script:AccentColor
            $null = & $KeyProvider
            return [pscustomobject]@{
                ReportSaved = $true
                ReportPath  = $reportPath
                ReportError = ''
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($reportError)) {
            Write-InstallerBlankLine
            Write-InstallerHeading -Title 'TECHNICAL REPORT' -TitleColor $script:AccentColor
            Write-InstallerRule -Level Group
            Write-InstallerDetailLine -Label 'REPORT ERROR' -Value $reportError -ValueColor $script:FailureColor -LabelColor $script:FailureColor
            Write-InstallerBlankLine
            Write-InstallerActionBar -PrimaryKey 'R' -PrimaryText 'TRY AGAIN' -PrimaryKeyColor $script:SuccessColor -SecondaryKey 'ANY OTHER KEY' -SecondaryText 'EXIT' -SecondaryKeyColor $script:WarningColor
        }
        else {
            Write-InstallerBlankLine
            Write-InstallerHeading -Title 'OPTIONAL TECHNICAL REPORT' -TitleColor $script:AccentColor
            Write-InstallerRule -Level Group
            Write-InstallerBodyLine -Text 'Save a developer/IT diagnostic report before closing this window.' -Color $script:MutedColor
            Write-InstallerBlankLine
            Write-InstallerActionBar -PrimaryKey 'R' -PrimaryText 'SAVE TECHNICAL REPORT' -PrimaryKeyColor $script:SuccessColor -SecondaryKey 'ANY OTHER KEY' -SecondaryText 'EXIT' -SecondaryKeyColor $script:WarningColor
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
        Write-InstallerBlankLine
        Write-InstallerHeading -Title 'REPORT DESTINATION' -TitleColor $script:AccentColor
        Write-InstallerRule -Level Group
        Write-InstallerBodyLine -Text 'Enter a folder or a complete .txt filename.' -Color $script:MutedColor
        Write-InstallerDetailLine -Label 'FOLDER' -Value (Split-Path -Parent $defaultReportPath)
        Write-InstallerDetailLine -Label 'FILE' -Value (Split-Path -Leaf $defaultReportPath)
        Write-InstallerBlankLine
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

    Write-InstallerBlankLine
    Write-InstallerRule -Level Screen
    Write-InstallerHeading -Title 'INSTALLATION SUMMARY' -TitleColor $script:TitleColor
    Write-InstallerRule -Level Screen
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
    Write-InstallerRule -Level Screen
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
