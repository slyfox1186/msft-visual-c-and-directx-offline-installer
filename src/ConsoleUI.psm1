Set-StrictMode -Version 2.0

$script:ConsoleWidth = 78
try {
    if (-not [Console]::IsOutputRedirected -and [Console]::WindowWidth -gt 1) {
        $script:ConsoleWidth = [math]::Min(110, [math]::Max(72, [Console]::WindowWidth - 1))
    }
}
catch { $script:ConsoleWidth = 78 }
$script:DiagnosticEvents = New-Object 'Collections.Generic.List[object]'
$script:StatusColors = @{ Ok = 'Green'; Restart = 'Yellow'; Retained = 'Yellow'; Failed = 'Red'; Info = 'DarkGray'; Cleanup = 'DarkGray' }

function Write-InstallerText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text = '',
        [AllowEmptyString()][string]$Prefix = '  ',
        [ConsoleColor]$Color = 'Gray',
        [ConsoleColor]$PrefixColor = 'DarkGray'
    )
    # Metadata, paths, and exception messages must not inject terminal controls.
    $remaining = ($Text -replace '[\r\n\t]', ' ' -replace '[^\x20-\x7e]', '?').Trim()
    $Prefix = $Prefix -replace '[^\x20-\x7e]', '?'
    if ($remaining.Length -eq 0) {
        Write-Host $Prefix.TrimEnd()
        return
    }
    $available = [math]::Max(1, $script:ConsoleWidth - $Prefix.Length)
    $first = $true
    while ($remaining.Length -gt 0) {
        $length = [math]::Min($available, $remaining.Length)
        if ($remaining.Length -gt $available) {
            $space = $remaining.LastIndexOf(' ', $available)
            if ($space -gt 0) { $length = $space }
        }
        $line = $remaining.Substring(0, $length).TrimEnd()
        $remaining = $remaining.Substring($length).TrimStart()
        if ($first) { Write-Host $Prefix -NoNewline -ForegroundColor $PrefixColor }
        else { Write-Host (' ' * $Prefix.Length) -NoNewline }
        Write-Host $line -ForegroundColor $Color
        $first = $false
    }
}

function Write-InstallerHeading {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Title, [ConsoleColor]$Color = 'Cyan')
    Write-Host ''
    Write-Host ('-' * $script:ConsoleWidth) -ForegroundColor DarkGray
    Write-InstallerText -Text $Title -Color $Color
    Write-Host ('-' * $script:ConsoleWidth) -ForegroundColor DarkGray
}

function Format-InstallerByteSize {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][ValidateRange(0, [long]::MaxValue)][long]$Bytes)
    foreach ($unit in @(@(1GB, 'GB'), @(1MB, 'MB'), @(1KB, 'KB'))) {
        if ($Bytes -ge $unit[0]) {
            return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:F2} {1}', ($Bytes / $unit[0]), $unit[1])
        }
    }
    return '{0} B' -f $Bytes
}

function Format-InstallerDuration {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][timespan]$Duration)
    if ($Duration.Ticks -lt 0) { throw 'Installer duration cannot be negative.' }
    if ($Duration.TotalHours -ge 1) {
        return '{0}:{1:00}:{2:00}' -f [math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds
    }
    return '{0:00}:{1:00}' -f $Duration.Minutes, $Duration.Seconds
}

function Format-InstallerPlan {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(0, [int]::MaxValue)][int]$DotNetPackageCount,
        [Parameter(Mandatory = $true)][ValidateRange(0, [int]::MaxValue)][int]$VisualCppPackageCount,
        [Parameter(Mandatory = $true)][bool]$DirectXSelected
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
    param([Parameter(Mandatory = $true)][ValidateSet('Download', 'Verify', 'Install', 'Info', 'Ok', 'Restart', 'Failed', 'Cleanup', 'Retained')][string]$State)
    $padding = 8 - $State.Length
    $left = [int][math]::Floor($padding / 2)
    return '[' + (' ' * $left) + $State.ToUpperInvariant() + (' ' * ($padding - $left)) + ']'
}

function Initialize-InstallerDiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidatePattern('\A[0-9a-fA-F-]{36}\z')][string]$RunId)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($RunId, [ref]$parsed)) { throw "Invalid installer diagnostic run ID: $RunId" }
    $script:DiagnosticEvents.Clear()
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
        [AllowEmptyString()][string]$DestinationPath = '',
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$DefaultDirectory,
        [datetime]$Timestamp = [datetime]::Now
    )
    $candidate = $DestinationPath.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $DefaultDirectory }
    elseif ($candidate.Length -ge 2 -and $candidate.StartsWith('"') -and $candidate.EndsWith('"')) {
        $candidate = $candidate.Substring(1, $candidate.Length - 2)
    }
    if ($candidate.Contains('"')) { throw 'The technical report path contains an unmatched quotation mark.' }
    try { $fullPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($candidate)) }
    catch { throw "Invalid technical report path: $($_.Exception.Message)" }
    $extension = [IO.Path]::GetExtension($fullPath)
    if ((Test-Path -LiteralPath $fullPath -PathType Container) -or [string]::IsNullOrWhiteSpace($extension) -or
        $candidate.EndsWith([IO.Path]::DirectorySeparatorChar) -or $candidate.EndsWith([IO.Path]::AltDirectorySeparatorChar)) {
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) { throw "The technical report directory is an existing file: $fullPath" }
        $fileName = 'Microsoft-Runtime-Installer-Report-{0}.txt' -f $Timestamp.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
        $fullPath = Join-Path $fullPath $fileName
    }
    elseif ($extension -ine '.txt') { throw 'The technical report filename must use the .txt extension.' }
    if (Test-Path -LiteralPath $fullPath) { throw "The technical report file already exists: $fullPath" }
    return $fullPath
}

function ConvertTo-InstallerReportText {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value, [Parameter(Mandatory = $true)][Collections.IDictionary]$Context)
    $text = [string]$Value -replace '[\x00-\x1f\x7f]', ' '
    foreach ($key in @('UserProfilePath', 'TempPath')) {
        if (-not $Context.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$Context[$key])) { continue }
        $path = ([string]$Context[$key]).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $replacement = if ($key -eq 'UserProfilePath') { '%USERPROFILE%' } else { '%TEMP%' }
        $text = [regex]::Replace($text, [regex]::Escape($path), $replacement, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    # Rejected URLs can contain spaces. Conservatively redact their remainder
    # when credential/query markers appear; retain the host when parsing works.
    return [regex]::Replace($text, '(?i)\b[a-z][a-z0-9+.-]*://.*', {
        param($match)
        if ($match.Value -notmatch '[@?#]') { return $match.Value }
        $parsed = $null
        if ([uri]::TryCreate($match.Value, [UriKind]::Absolute, [ref]$parsed)) {
            return '{0}://{1}/[REDACTED]' -f $parsed.Scheme, $parsed.DnsSafeHost
        }
        return '[REDACTED URL]'
    })
}

function Export-InstallerTechnicalReport {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$DestinationPath = '',
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$DefaultDirectory,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Context,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][psobject[]]$Events,
        [datetime]$Timestamp = [datetime]::Now
    )
    $required = @('RunId', 'SourceRevision', 'StartedAt', 'CompletedAt', 'Outcome', 'ExitCode',
        'CompletedPackageCount', 'PlannedPackageCount', 'Duration', 'RestartRequired', 'CleanupStatus',
        'DownloadsRetained', 'RetainedWorkspacePath', 'FailureMessage', 'ComputerName', 'OperatingSystem',
        'Architecture', 'PowerShell', 'CurlVersion', 'Culture', 'Components', 'DotNetChannels',
        'VisualCppVersions', 'ResolvedPackages', 'SecurityControls', 'UserProfilePath', 'TempPath')
    foreach ($key in $required) {
        if (-not $Context.Contains($key)) { throw "Technical report context is missing required key: $key" }
    }
    if ([string]$Context.Outcome -notin @('Success', 'Restart', 'Failed')) { throw 'Technical report context contains an invalid outcome.' }
    $reportPath = Resolve-InstallerReportPath -DestinationPath $DestinationPath -DefaultDirectory $DefaultDirectory -Timestamp $Timestamp
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $reportPath))
    $restart = if ($Context.RestartRequired) { 'Required - restart Windows manually' } else { 'Not required' }
    $retention = if ($Context.DownloadsRetained) { 'Retained' } else { 'Removed unless cleanup failed' }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $sections = [ordered]@{
        'EXECUTIVE RESULT' = [ordered]@{
            'Outcome' = ([string]$Context.Outcome).ToUpperInvariant(); 'Process exit code' = $Context.ExitCode
            'Packages completed' = '{0} of {1}' -f $Context.CompletedPackageCount, $Context.PlannedPackageCount
            'Elapsed time' = Format-InstallerDuration ([timespan]$Context.Duration); 'Restart' = $restart; 'Cleanup' = $Context.CleanupStatus
        }
        'RUN IDENTITY' = [ordered]@{
            'Report schema' = 1; 'Run ID' = $Context.RunId; 'Source revision' = $Context.SourceRevision
            'Started (local)' = ([datetimeoffset]$Context.StartedAt).ToString('o', $culture)
            'Completed (local)' = ([datetimeoffset]$Context.CompletedAt).ToString('o', $culture)
            'Completed (UTC)' = ([datetimeoffset]$Context.CompletedAt).UtcDateTime.ToString('o', $culture)
        }
        'SYSTEM CONTEXT' = [ordered]@{
            'Computer name' = $Context.ComputerName; 'Operating system' = $Context.OperatingSystem
            'Target architecture' = $Context.Architecture; 'PowerShell' = $Context.PowerShell
            'curl' = $Context.CurlVersion; 'Culture' = $Context.Culture; 'Elevated' = 'Yes'
        }
        'REQUESTED AND RESOLVED PLAN' = [ordered]@{
            'Components' = $Context.Components; '.NET channels' = $Context.DotNetChannels
            'Visual C++ families' = $Context.VisualCppVersions; 'Resolved package count' = @($Context.ResolvedPackages).Count
        }
        'SECURITY AND CLEANUP' = [ordered]@{
            'Download retention' = $retention; 'Retained workspace' = $Context.RetainedWorkspacePath; 'Cleanup result' = $Context.CleanupStatus
        }
    }
    $lines = New-Object 'Collections.Generic.List[string]'
    $lines.Add('MICROSOFT RUNTIME INSTALLER - TECHNICAL REPORT')
    $lines.Add('=' * $script:ConsoleWidth)
    $lines.Add('Review before external sharing: this report includes a computer name and OS details.')
    $lines.Add('It excludes credentials, environment-variable dumps, and package contents.')
    foreach ($section in $sections.GetEnumerator()) {
        $lines.Add('')
        $lines.Add($section.Key)
        $lines.Add('-' * $script:ConsoleWidth)
        foreach ($row in $section.Value.GetEnumerator()) {
            $value = ConvertTo-InstallerReportText -Value $row.Value -Context $Context
            $lines.Add(('{0,-25}: {1}' -f $row.Key, $value))
        }
        if ($section.Key -eq 'REQUESTED AND RESOLVED PLAN') {
            if (@($Context.ResolvedPackages).Count -eq 0) { $lines.Add('  No package list was resolved before the run stopped.') }
            foreach ($package in @($Context.ResolvedPackages)) { $lines.Add('  ' + (ConvertTo-InstallerReportText $package $Context)) }
        }
        if ($section.Key -eq 'SECURITY AND CLEANUP') {
            foreach ($control in @($Context.SecurityControls)) { $lines.Add('  - ' + (ConvertTo-InstallerReportText $control $Context)) }
        }
    }
    $lines.Add('')
    $lines.Add('EVENT TIMELINE')
    $lines.Add('-' * $script:ConsoleWidth)
    if ($Events.Count -eq 0) { $lines.Add('No structured diagnostic events were captured.') }
    foreach ($diagnosticEvent in $Events) {
        $eventTime = ([datetimeoffset]$diagnosticEvent.Timestamp).ToString('o', $culture)
        $state = ConvertTo-InstallerReportText -Value ([string]$diagnosticEvent.State).ToUpperInvariant() -Context $Context
        $lines.Add(('{0} | {1,-8} | {2}' -f $eventTime, $state, (ConvertTo-InstallerReportText $diagnosticEvent.Message $Context)))
    }
    $lines.Add('')
    $lines.Add('FAILURE ANALYSIS / NEXT ACTIONS')
    $lines.Add('-' * $script:ConsoleWidth)
    if ($Context.Outcome -eq 'Failed') {
        $lines.Add('Failure reason: ' + (ConvertTo-InstallerReportText $Context.FailureMessage $Context))
        $lines.Add('1. Locate the first FAILED event and the package or phase immediately before it.')
        $lines.Add('2. Confirm network access to the reported Microsoft host and sufficient disk space.')
        $lines.Add('3. Retry from an Administrator console; attach this report if the failure repeats.')
    }
    elseif ($Context.RestartRequired) { $lines.Add('No installation failure was recorded. Restart Windows manually to finish setup.') }
    else { $lines.Add('No installation failure or restart requirement was recorded.') }
    $lines.Add('')
    $lines.Add('=' * $script:ConsoleWidth)
    $lines.Add('END OF REPORT')
    # CreateNew enforces no-overwrite atomically, including competing writers.
    $stream = New-Object IO.FileStream($reportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($true)))
        try { $writer.Write(($lines -join [Environment]::NewLine) + [Environment]::NewLine) }
        finally { $writer.Dispose() }
    }
    finally { $stream.Dispose() }
    return $reportPath
}

function Write-InstallerBanner {
    [CmdletBinding()]
    param()
    Write-InstallerHeading -Title 'MICROSOFT RUNTIME INSTALLER' -Color White
    Write-InstallerText 'SECURE DOWNLOADS | VERIFIED FILES | AUTO CLEANUP' -Color DarkGray
}

function Write-InstallerHelp {
    [CmdletBinding()]
    param()
    Write-InstallerBanner
    Write-InstallerHeading 'USAGE'
    Write-InstallerText 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1 [options]'
    Write-InstallerText 'pwsh.exe -NoProfile -File .\Install.ps1 [options]'
    Write-InstallerText 'Run without selection options for the menu. Explicit selections bypass it for automation.'
    Write-InstallerHeading 'OPTIONS'
    $options = [ordered]@{
        '-Components <list>' = 'All (default), DotNet, VisualCpp, DirectX'
        '-ExcludeComponents <list>' = 'Remove component groups from the enabled set'
        '-DotNetChannels <list>' = 'All, or supported channels such as 8.0,10.0'
        '-VisualCppVersions <list>' = 'All, 2005, 2008, 2010, 2012, 2013, or v14'
        '-KeepDownloads' = 'Keep the Microsoft installer workspace'
        '-ReportPath <path>' = 'Write a UTF-8 developer/IT .txt report'
        '-h | -Help | --help' = 'Show help without UAC or downloads'
    }
    foreach ($option in $options.GetEnumerator()) { Write-InstallerText $option.Value -Prefix ('  ' + $option.Key.PadRight(27)) }
    Write-InstallerHeading 'RULES'
    foreach ($rule in @(
        'Separate values with commas. Values are case-insensitive. Use All alone; duplicates are rejected.',
        'Architecture is automatic and cannot be overridden. Filters require their component to be enabled.',
        '.NET resolves the latest stable SDK in each selected supported channel.',
        '.NET latest.version is accepted only with Microsoft SHA-512 metadata.',
        'Visual C++ v14 tracks the latest supported release and requires a valid Microsoft signature and version floor.',
        'Legacy Visual C++ and DirectX are final fixed releases requiring reviewed SHA-256 and Microsoft signatures.',
        'Every Microsoft package source is resolved when the run starts.',
        'Microsoft progress windows require no clicks. Packages never restart Windows automatically.',
        'Downloads are removed by default, including after failures.'
    )) { Write-InstallerText $rule -Prefix '  * ' }
    Write-InstallerHeading 'EXAMPLES'
    foreach ($example in @('.\Install.ps1', '.\Install.ps1 -Components DotNet,DirectX -DotNetChannels 8.0,10.0',
        '.\Install.ps1 -Components VisualCpp -VisualCppVersions 2013,v14',
        '.\Install.ps1 -ExcludeComponents DirectX -KeepDownloads',
        '.\Install.ps1 -Components DotNet -ReportPath "$env:USERPROFILE"')) { Write-InstallerText $example }
    Write-InstallerHeading 'EXIT CODES'
    Write-InstallerText '0 = Success | 1 = Failure | 2 = Cancelled before installation | 3010 = Success; restart required'
}

function Clear-InstallerScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][scriptblock]$ScreenClearer)
    try { $null = & $ScreenClearer }
    catch { $null = $_ } # Unsupported screen clearing must not interrupt installation.
}

function Read-InstallerSelection {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [scriptblock]$InputProvider = { param($Prompt) Read-Host -Prompt $Prompt },
        [scriptblock]$ScreenClearer = { [Console]::Clear() },
        [bool]$InitialKeepDownloads = $false
    )
    $components = @('DotNet', 'VisualCpp', 'DirectX')
    $labels = @('.NET SDKs', 'Visual C++ Redistributables', 'DirectX Legacy Runtime')
    $details = @('Latest stable SDK in each selected supported channel',
        'Latest supported v14 plus final 2005-2013 releases', 'Final June 2010 legacy release')
    $enabled = @{ DotNet = $true; VisualCpp = $true; DirectX = $true }
    $filters = @{ DotNet = 'All'; VisualCpp = 'All' }
    $keepDownloads = $InitialKeepDownloads
    $feedback = ''
    $feedbackColor = 'Gray'
    while ($true) {
        Clear-InstallerScreen $ScreenClearer
        Write-InstallerBanner
        Write-InstallerHeading ('SELECT PACKAGES | {0} OF 3 SELECTED' -f @($enabled.Values | Where-Object { $_ }).Count)
        Write-InstallerText 'Type a choice and press ENTER. Press 1, 2, or 3 to toggle a group.'
        for ($index = 0; $index -lt 3; $index++) {
            $state = if ($enabled[$components[$index]]) { 'ON ' } else { 'OFF' }
            $color = if ($enabled[$components[$index]]) { 'Green' } else { 'DarkGray' }
            Write-InstallerText $labels[$index] -Prefix ('  [{0}] {1}  ' -f ($index + 1), $state) -PrefixColor $color
            Write-InstallerText $details[$index] -Prefix '           ' -Color DarkGray
        }
        Write-InstallerHeading 'OPTIONAL SETTINGS'
        foreach ($entry in @(@('4', 'DotNet', '.NET SDK channels'), @('5', 'VisualCpp', 'Visual C++ release families'))) {
            $value = if ($enabled[$entry[1]]) { $filters[$entry[1]] } else { 'Unavailable - enable the package group first' }
            Write-InstallerText ('{0}: {1}' -f $entry[2], $value) -Prefix ('  [{0}] ' -f $entry[0])
        }
        $retention = if ($keepDownloads) { 'Yes - retain files after installation' } else { 'No - remove files after installation' }
        Write-InstallerText ('Keep downloaded installers: ' + $retention) -Prefix '  [K] '
        Write-InstallerText 'Restore all package groups and version choices' -Prefix '  [A] '
        Write-InstallerHeading '[ENTER] INSTALL SELECTED PACKAGES | [Q] CANCEL'
        if ($feedback) { Write-InstallerText $feedback -Color $feedbackColor }
        $rawChoice = & $InputProvider 'Selection'
        if ($null -eq $rawChoice) { throw 'Interactive input ended. Use explicit component switches for automation.' }
        $choice = ([string]$rawChoice).Trim().ToUpperInvariant()
        $feedbackColor = 'Green'
        if ($choice -eq '' -or $choice -eq 'Q') {
            $selected = @($components | Where-Object { $enabled[$_] })
            if ($choice -eq '' -and $selected.Count -eq 0) {
                $feedback = 'Select at least one package group.'
                $feedbackColor = 'Red'
                continue
            }
            Clear-InstallerScreen $ScreenClearer
            if ($choice -eq 'Q') { Write-InstallerStatus Info 'Installation cancelled before elevation or downloads.' }
            return [pscustomobject]@{
                Components = if ($choice -eq 'Q') { '' } else { $selected -join ',' }
                DotNetChannels = if ($choice -ne 'Q' -and $enabled.DotNet) { $filters.DotNet } else { 'All' }
                VisualCppVersions = if ($choice -ne 'Q' -and $enabled.VisualCpp) { $filters.VisualCpp } else { 'All' }
                KeepDownloads = $keepDownloads; Cancelled = $choice -eq 'Q'
            }
        }
        if ($choice -match '\A[1-3]\z') {
            $component = $components[[int]$choice - 1]
            $enabled[$component] = -not $enabled[$component]
            $feedback = 'Package selection updated.'
            continue
        }
        if ($choice -eq 'A') {
            foreach ($component in $components) { $enabled[$component] = $true }
            $filters.DotNet = 'All'
            $filters.VisualCpp = 'All'
            $feedback = 'All package groups and version choices restored.'
            continue
        }
        if ($choice -eq 'K') {
            $keepDownloads = -not $keepDownloads
            $feedback = 'Download retention updated.'
            continue
        }
        if ($choice -eq '4' -or $choice -eq '5') {
            $component = if ($choice -eq '4') { 'DotNet' } else { 'VisualCpp' }
            $feedbackColor = 'Red'
            if (-not $enabled[$component]) {
                $feedback = 'Enable the package group before choosing its versions.'
                continue
            }
            $prompt = if ($component -eq 'DotNet') { '.NET SDK channels (All or example: 8.0,10.0)' } else { 'Visual C++ release families (All or example: 2013,v14)' }
            $rawValue = & $InputProvider $prompt
            if ($null -eq $rawValue) { throw 'Interactive input ended while choosing package versions.' }
            $candidate = ([string]$rawValue).Trim() -replace '[ \t]', ''
            $tokenPattern = if ($component -eq 'DotNet') { '\d+\.\d+' } else { '(?:2005|2008|2010|2012|2013|v14)' }
            $tokens = @($candidate.Split(','))
            $uniqueTokens = @($tokens | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
            if ($candidate -notmatch ('\A(?:All|{0}(?:,{0})*)\z' -f $tokenPattern) -or
                $uniqueTokens.Count -ne $tokens.Count) {
                $feedback = 'Use All alone or valid comma-separated versions without duplicates.'
                continue
            }
            $filters[$component] = $candidate
            $feedback = 'Version selection updated.'
            $feedbackColor = 'Green'
            continue
        }
        $feedback = "Unknown selection '$choice'. Choose 1-5, A, K, ENTER, or Q."
        $feedbackColor = 'Red'
    }
}

function Write-InstallerSystemSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$PowerShellVersion,
        [string]$PowerShellEdition = '',
        [Parameter(Mandatory = $true)][string]$CurlVersion,
        [Parameter(Mandatory = $true)][int]$DotNetPackageCount,
        [Parameter(Mandatory = $true)][int]$VisualCppPackageCount,
        [Parameter(Mandatory = $true)][bool]$DirectXSelected,
        [Parameter(Mandatory = $true)][ValidateRange(0, [int]::MaxValue)][int]$FixedHashPackageCount,
        [Parameter(Mandatory = $true)][bool]$RollingVisualCppSelected
    )
    if ($PowerShellEdition) { $PowerShellVersion += " ($PowerShellEdition)" }
    $controls = @('approved Microsoft HTTPS sources')
    if ($DotNetPackageCount -gt 0) { $controls += '.NET SHA-512 hashes' }
    if ($FixedHashPackageCount -gt 0) { $controls += 'fixed-package SHA-256 hashes' }
    if ($VisualCppPackageCount -gt 0 -or $DirectXSelected) { $controls += 'Microsoft digital signatures' }
    if ($RollingVisualCppSelected) { $controls += 'v14 version floor' }
    Write-InstallerHeading 'SYSTEM AND PLAN'
    Write-InstallerStatus Info "System: Windows $Architecture | PowerShell $PowerShellVersion | curl $CurlVersion"
    Write-InstallerStatus Info ('Install plan: ' + (Format-InstallerPlan $DotNetPackageCount $VisualCppPackageCount $DirectXSelected))
    Write-InstallerStatus Info ('Security checks: ' + ($controls -join ' | '))
    Write-InstallerStatus Info 'Temporary files: isolated for this run; removed when finished unless retention was selected'
}

function Write-InstallerSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 99)][int]$Number,
        [Parameter(Mandatory = $true)][ValidateRange(1, 99)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Title
    )
    $script:DiagnosticEvents.Add([pscustomobject]@{ Timestamp = [datetimeoffset]::Now; State = 'Phase'; Message = "Phase $Number of ${Total}: $Title" })
    Write-InstallerHeading ('PHASE {0} OF {1} | {2}' -f $Number, $Total, $Title.ToUpperInvariant())
}

function Write-InstallerStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Download', 'Verify', 'Install', 'Info', 'Ok', 'Restart', 'Failed', 'Cleanup', 'Retained')][string]$State,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $script:DiagnosticEvents.Add([pscustomobject]@{ Timestamp = [datetimeoffset]::Now; State = $State; Message = $Message })
    $color = if ($script:StatusColors.ContainsKey($State)) { $script:StatusColors[$State] } else { 'Cyan' }
    $textColor = if ($State -in @('Failed', 'Restart', 'Retained')) { $color } else { 'Gray' }
    $prefix = '[{0}] {1} ' -f [datetime]::Now.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), (Get-InstallerStatusBadge $State)
    Write-InstallerText $Message -Prefix $prefix -PrefixColor $color -Color $textColor
}

function Write-InstallerCompletionScreen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Success', 'Restart', 'Failed')][string]$Outcome,
        [Parameter(Mandatory = $true)][ValidateRange(0, [int]::MaxValue)][int]$CompletedPackageCount,
        [Parameter(Mandatory = $true)][ValidateRange(0, [int]::MaxValue)][int]$PlannedPackageCount,
        [Parameter(Mandatory = $true)][timespan]$Duration,
        [Parameter(Mandatory = $true)][bool]$CleanupSucceeded,
        [Parameter(Mandatory = $true)][bool]$RestartRequired,
        [bool]$DownloadsRetained = $false,
        [string]$RetainedWorkspacePath = '',
        [string]$Message = '',
        [string]$ReportPath = ''
    )
    $headings = @{ Success = 'INSTALLATION COMPLETED SUCCESSFULLY'; Restart = 'INSTALLATION COMPLETED - RESTART REQUIRED'; Failed = 'INSTALLATION NEEDS ATTENTION' }
    $colors = @{ Success = 'Green'; Restart = 'Yellow'; Failed = 'Red' }
    Write-InstallerHeading $headings[$Outcome] -Color $colors[$Outcome]
    $restart = if ($RestartRequired) { 'Restart Windows manually to finish setup.' }
        elseif ($Outcome -eq 'Failed') { 'No restart was reported before the failure.' } else { 'No restart is required.' }
    if ($RestartRequired -and $Outcome -eq 'Failed') { $restart = 'A completed package requested a restart.' }
    $downloads = if ($DownloadsRetained) { "Downloaded files were kept at: $RetainedWorkspacePath" }
        elseif ($CleanupSucceeded) { 'Temporary downloads were removed.' } else { 'Temporary download cleanup did not complete.' }
    $rows = [ordered]@{
        RESULT = $Outcome.ToUpperInvariant(); PACKAGES = "$CompletedPackageCount of $PlannedPackageCount completed"
        ELAPSED = Format-InstallerDuration $Duration; RESTART = $restart; DOWNLOADS = $downloads
    }
    if ($Outcome -eq 'Failed') {
        $rows.ERROR = if ([string]::IsNullOrWhiteSpace($Message)) { 'No additional failure detail was recorded.' } else { $Message }
    }
    if ($ReportPath) {
        $rows['REPORT DIR'] = Split-Path -Parent $ReportPath
        $rows['REPORT FILE'] = Split-Path -Leaf $ReportPath
    }
    foreach ($row in $rows.GetEnumerator()) { Write-InstallerText $row.Value -Prefix ('  ' + $row.Key.PadRight(14)) }
    if ($Outcome -eq 'Failed') { Write-InstallerText 'Save the technical report for detailed diagnostics before retrying.' -Color Yellow }
    elseif ($Outcome -eq 'Restart') { Write-InstallerText 'The installer did not restart Windows automatically.' -Color Yellow }
}

function Invoke-InstallerCompletionPrompt {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Success', 'Restart', 'Failed')][string]$Outcome,
        [Parameter(Mandatory = $true)][ValidateRange(0, [int]::MaxValue)][int]$CompletedPackageCount,
        [Parameter(Mandatory = $true)][ValidateRange(0, [int]::MaxValue)][int]$PlannedPackageCount,
        [Parameter(Mandatory = $true)][timespan]$Duration,
        [Parameter(Mandatory = $true)][bool]$CleanupSucceeded,
        [Parameter(Mandatory = $true)][bool]$RestartRequired,
        [bool]$DownloadsRetained = $false,
        [string]$RetainedWorkspacePath = '',
        [string]$Message = '',
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$DefaultReportDirectory,
        [datetime]$Timestamp = [datetime]::Now,
        [scriptblock]$ScreenClearer = { [Console]::Clear() },
        [scriptblock]$KeyProvider = { [Console]::ReadKey($true).KeyChar },
        [scriptblock]$InputProvider = { param($Prompt) Read-Host -Prompt $Prompt },
        [Parameter(Mandatory = $true)][scriptblock]$ReportExporter,
        [string]$ExistingReportPath = '',
        [string]$InitialReportError = ''
    )
    $screen = @{
        Outcome = $Outcome; CompletedPackageCount = $CompletedPackageCount; PlannedPackageCount = $PlannedPackageCount
        Duration = $Duration; CleanupSucceeded = $CleanupSucceeded; RestartRequired = $RestartRequired
        DownloadsRetained = $DownloadsRetained; RetainedWorkspacePath = $RetainedWorkspacePath; Message = $Message
    }
    $reportPath = $ExistingReportPath
    $reportError = $InitialReportError
    while ($true) {
        Clear-InstallerScreen $ScreenClearer
        Write-InstallerCompletionScreen @screen -ReportPath $reportPath
        if (-not [string]::IsNullOrWhiteSpace($reportPath)) {
            Write-InstallerHeading 'TECHNICAL REPORT SAVED' -Color Green
            Write-InstallerText '[ANY KEY] EXIT WHEN YOU ARE READY'
            $null = & $KeyProvider
            break
        }
        Write-InstallerHeading 'OPTIONAL TECHNICAL REPORT'
        if ($reportError) { Write-InstallerText ('REPORT ERROR: ' + $reportError) -Color Red }
        Write-InstallerText '[R] SAVE / RETRY TECHNICAL REPORT | [ANY OTHER KEY] EXIT' -Color Yellow
        $key = & $KeyProvider
        $keyText = if ($key -is [ConsoleKeyInfo]) { [string]$key.KeyChar } else { [string]$key }
        if ($keyText -ine 'R') { break }
        Write-InstallerText 'Enter a folder or a complete .txt filename.'
        Write-InstallerText ("Leave blank for a timestamped report in: $DefaultReportDirectory")
        try {
            # Resolve only the chosen destination, inside the retry boundary.
            $requested = & $InputProvider 'Report path (press ENTER for the default)'
            $resolved = Resolve-InstallerReportPath -DestinationPath ([string]$requested) -DefaultDirectory $DefaultReportDirectory -Timestamp $Timestamp
            $reportPath = [string](& $ReportExporter $resolved)
            if ([string]::IsNullOrWhiteSpace($reportPath) -or -not [IO.Path]::IsPathRooted($reportPath)) {
                throw 'The report exporter did not return a complete report path.'
            }
            $reportError = ''
        }
        catch {
            $reportPath = ''
            $reportError = $_.Exception.Message
        }
    }
    return [pscustomobject]@{ ReportSaved = -not [string]::IsNullOrWhiteSpace($reportPath); ReportPath = $reportPath; ReportError = $reportError }
}

function Write-InstallerSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Success', 'Restart', 'Failed')][string]$Outcome,
        [Parameter(Mandatory = $true)][ValidateRange(0, [int]::MaxValue)][int]$CompletedPackageCount,
        [Parameter(Mandatory = $true)][timespan]$Duration,
        [Parameter(Mandatory = $true)][bool]$CleanupSucceeded,
        [string]$RetainedWorkspacePath = '',
        [string]$Message = ''
    )
    Write-InstallerHeading 'INSTALLATION SUMMARY'
    switch ($Outcome) {
        'Success' { Write-InstallerStatus Ok 'Installation completed successfully.' }
        'Restart' { Write-InstallerStatus Restart 'Installation completed successfully. Restart Windows to finish.' }
        'Failed' { Write-InstallerStatus Failed "Installation stopped: $Message" }
    }
    Write-InstallerStatus Info ("Packages completed: {0} | Elapsed: {1}" -f $CompletedPackageCount, (Format-InstallerDuration $Duration))
    if ($RetainedWorkspacePath) { Write-InstallerStatus Retained "Installer workspace retained at: $RetainedWorkspacePath" }
    elseif ($CleanupSucceeded) { Write-InstallerStatus Cleanup 'Temporary download files were removed.' }
    else { Write-InstallerStatus Failed 'Temporary download cleanup did not complete; review the error above.' }
}

Export-ModuleMember -Function @(
    'Format-InstallerByteSize', 'Format-InstallerDuration', 'Format-InstallerPlan',
    'Export-InstallerTechnicalReport', 'Get-InstallerDiagnosticEvent', 'Get-InstallerStatusBadge',
    'Invoke-InstallerCompletionPrompt', 'Read-InstallerSelection', 'Initialize-InstallerDiagnostic',
    'Resolve-InstallerReportPath', 'Write-InstallerBanner', 'Write-InstallerCompletionScreen',
    'Write-InstallerHelp', 'Write-InstallerSection', 'Write-InstallerStatus',
    'Write-InstallerSummary', 'Write-InstallerSystemSummary'
)
