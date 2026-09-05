#Requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/ConsoleUI.psm1') -Force
$script:Failures = 0
$script:Checks = 0

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Check {
    param([string]$Name, [scriptblock]$Check)
    $script:Checks++
    try { & $Check; Write-Host "PASS $Name" }
    catch { $script:Failures++; Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}

function Get-InputProvider {
    param([AllowEmptyCollection()][string[]]$Values)
    $queue = New-Object 'Collections.Generic.Queue[string]'
    foreach ($value in $Values) { $queue.Enqueue($value) }
    return { if ($queue.Count -eq 0) { throw 'Unexpected extra prompt.' }; $queue.Dequeue() }.GetNewClosure()
}

function Get-ConsoleText {
    param([scriptblock]$Action)
    $builder = New-Object Text.StringBuilder
    foreach ($record in @(& $Action 6>&1)) {
        if ($record -isnot [Management.Automation.InformationRecord]) { continue }
        $null = $builder.Append([string]$record.MessageData.Message)
        if (-not $record.MessageData.NoNewLine) { $null = $builder.AppendLine() }
    }
    return $builder.ToString()
}

$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('msri-ui-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempDirectory
$timestamp = [datetime]'2026-09-05T12:00:00'
$context = @{
    RunId = [guid]::NewGuid().ToString(); SourceRevision = 'Local source'
    StartedAt = [datetimeoffset]$timestamp; CompletedAt = [datetimeoffset]$timestamp
    Outcome = 'Failed'; ExitCode = 1; CompletedPackageCount = 1; PlannedPackageCount = 2
    Duration = [timespan]::FromSeconds(90); RestartRequired = $true
    CleanupStatus = 'Removed successfully'; DownloadsRetained = $false
    RetainedWorkspacePath = ''; FailureMessage = 'Example failure'
    ComputerName = 'TEST-PC'; OperatingSystem = 'Windows test fixture'; Architecture = 'x64'
    PowerShell = '5.1 (Desktop)'; CurlVersion = 'test'; Culture = 'en-US'
    Components = 'DotNet,VisualCpp'; DotNetChannels = 'All'; VisualCppVersions = 'v14'
    ResolvedPackages = @('Example package'); SecurityControls = @('SHA-512 verification')
    UserProfilePath = 'C:\Users\Example'; TempPath = 'C:\Temp'
}
$completion = @{
    Outcome = 'Success'; CompletedPackageCount = 1; PlannedPackageCount = 1
    Duration = [timespan]::Zero; CleanupSucceeded = $true; RestartRequired = $false
    DefaultReportDirectory = $tempDirectory; Timestamp = $timestamp; ScreenClearer = {}
}

try {
    Invoke-Check 'exports remain compatible' {
        $expected = @('Format-InstallerByteSize', 'Format-InstallerDuration', 'Format-InstallerPlan',
            'Export-InstallerTechnicalReport', 'Get-InstallerDiagnosticEvent', 'Get-InstallerStatusBadge',
            'Invoke-InstallerCompletionPrompt', 'Read-InstallerSelection', 'Initialize-InstallerDiagnostic',
            'Resolve-InstallerReportPath', 'Write-InstallerBanner', 'Write-InstallerCompletionScreen',
            'Write-InstallerHelp', 'Write-InstallerSection', 'Write-InstallerStatus', 'Write-InstallerSummary',
            'Write-InstallerSystemSummary')
        $actual = @((Get-Module ConsoleUI).ExportedFunctions.Keys)
        Assert-Condition (@(Compare-Object $expected $actual).Count -eq 0) 'Export list changed.'
    }
    Invoke-Check 'formatting and centered badges' {
        Assert-Condition ((Format-InstallerByteSize 1536) -eq '1.50 KB') 'Byte formatting changed.'
        Assert-Condition ((Format-InstallerDuration ([timespan]::FromSeconds(3661))) -eq '1:01:01') 'Duration changed.'
        Assert-Condition ((Get-InstallerStatusBadge Ok) -eq '[   OK   ]') 'Badge not centered.'
        Assert-Condition ((Get-InstallerStatusBadge Download).Length -eq 10) 'Badge width changed.'
        Assert-Condition ((Format-InstallerPlan 1 2 $true) -match 'DirectX June 2010') 'Plan lost DirectX.'
    }
    Invoke-Check 'default selection, retention, and cancellation' {
        $selected = Read-InstallerSelection -InputProvider (Get-InputProvider @('')) -ScreenClearer {} 6>$null
        Assert-Condition ($selected.Components -eq 'DotNet,VisualCpp,DirectX' -and -not $selected.Cancelled) 'Defaults changed.'
        $cancelled = Read-InstallerSelection -InitialKeepDownloads $true -InputProvider (Get-InputProvider @('Q')) -ScreenClearer { throw 'No screen' } 6>$null
        Assert-Condition ($cancelled.Cancelled -and $cancelled.KeepDownloads) 'Cancellation/retention changed.'
    }
    Invoke-Check 'custom selection rejects duplicates and disabled filters' {
        $selected = Read-InstallerSelection -InputProvider (Get-InputProvider @('1', '4', '1', '4', '8.0,8.0', '4', '8.0,10.0', '5', '2013,v14', '3', 'K', '')) -ScreenClearer {} 6>$null
        Assert-Condition ($selected.Components -eq 'DotNet,VisualCpp') 'Toggles changed.'
        Assert-Condition ($selected.DotNetChannels -eq '8.0,10.0' -and $selected.VisualCppVersions -eq '2013,v14') 'Filters changed.'
        Assert-Condition $selected.KeepDownloads 'Keep-download toggle failed.'
    }
    Invoke-Check 'empty version input returns to the menu' {
        $selected = Read-InstallerSelection -InputProvider (Get-InputProvider @('4', '', '5', '', 'Q')) -ScreenClearer {} 6>$null
        Assert-Condition $selected.Cancelled 'Empty filter prevented cancellation.'
    }
    Invoke-Check 'version duplicates are case insensitive' {
        $selected = Read-InstallerSelection -InputProvider (Get-InputProvider @('5', 'v14,V14', '')) -ScreenClearer {} 6>$null
        Assert-Condition ($selected.VisualCppVersions -eq 'All') 'Case-variant duplicate accepted.'
    }
    Invoke-Check 'an empty plan cannot be confirmed and reset restores groups' {
        $selected = Read-InstallerSelection -InputProvider (Get-InputProvider @('1', '2', '3', '', 'A', '')) -ScreenClearer {} 6>$null
        Assert-Condition ($selected.Components -eq 'DotNet,VisualCpp,DirectX') 'Empty plan accepted or reset failed.'
    }
    Invoke-Check 'input exhaustion fails without confirming a plan' {
        $rejected = $false
        try { $null = Read-InstallerSelection -InputProvider { $null } -ScreenClearer {} 6>$null }
        catch { $rejected = $_.Exception.Message -match 'Interactive input ended' }
        Assert-Condition $rejected 'Input exhaustion silently confirmed a plan.'
    }
    Invoke-Check 'console sanitizes untrusted characters and wraps all widths' {
        $module = Get-Module ConsoleUI
        foreach ($width in @(72, 78, 110)) {
            & $module { param($value) $script:ConsoleWidth = $value } $width
            $text = Get-ConsoleText {
                Write-InstallerStatus Info ('Untrusted ' + [char]0x00e9 + "`n" + [char]27 + '[31m ' + ('X' * 180))
                Write-InstallerCompletionScreen -Outcome Failed -CompletedPackageCount 1 -PlannedPackageCount 2 -Duration ([timespan]::Zero) -CleanupSucceeded $false -RestartRequired $true -Message ('failure ' * 30)
                Write-InstallerHelp
            }
            foreach ($line in ($text -split '\r?\n')) {
                Assert-Condition ($line -notmatch '[^\x20-\x7e]') "Non-ASCII console text at width $width."
                Assert-Condition ($line.Length -le $width) "Line exceeds $width columns: $($line.Length)."
            }
        }
        & $module { $script:ConsoleWidth = 78 }
    }
    Invoke-Check 'events retain state, timestamps, and clear between runs' {
        Initialize-InstallerDiagnostic -RunId ([guid]::NewGuid().ToString())
        Write-InstallerStatus -State Verify -Message 'Verified fixture' 6>$null
        Write-InstallerSection -Number 1 -Total 1 -Title 'Fixture' 6>$null
        $events = @(Get-InstallerDiagnosticEvent)
        Assert-Condition ($events.Count -eq 2 -and $events[0].State -eq 'Verify' -and $events[1].State -eq 'Phase') 'Events missing.'
        Assert-Condition ($events[0].Timestamp -is [datetimeoffset]) 'Timestamp type changed.'
        Initialize-InstallerDiagnostic -RunId ([guid]::NewGuid().ToString())
        Assert-Condition (@(Get-InstallerDiagnosticEvent).Count -eq 0) 'Previous events retained.'
    }
    Invoke-Check 'report writes structured context and never overwrites' {
        $path = Export-InstallerTechnicalReport -DefaultDirectory $tempDirectory -DestinationPath (Join-Path $tempDirectory 'report.txt') -Context $context -Events @() -Timestamp $timestamp
        $original = [IO.File]::ReadAllText($path)
        foreach ($expected in @('RUN IDENTITY', 'TEST-PC', 'Example package', 'EVENT TIMELINE', 'Example failure', 'SHA-512 verification', 'END OF REPORT')) {
            Assert-Condition ($original.Contains($expected)) "Missing report content: $expected"
        }
        $rejected = $false
        try { $null = Export-InstallerTechnicalReport -DefaultDirectory $tempDirectory -DestinationPath $path -Context $context -Events @() }
        catch { $rejected = $true }
        Assert-Condition ($rejected -and [IO.File]::ReadAllText($path) -ceq $original) 'Existing report overwritten.'
    }
    Invoke-Check 'report paths and missing context are rejected before writing' {
        foreach ($candidate in @('bad.csv', 'bad"name.txt')) {
            $rejected = $false
            try { $null = Resolve-InstallerReportPath -DefaultDirectory $tempDirectory -DestinationPath (Join-Path $tempDirectory $candidate) }
            catch { $rejected = $true }
            Assert-Condition $rejected "Invalid report path accepted: $candidate"
        }
        $rejected = $false
        try { $null = Export-InstallerTechnicalReport -DefaultDirectory $tempDirectory -DestinationPath (Join-Path $tempDirectory 'incomplete.txt') -Context @{} -Events @() }
        catch { $rejected = $_.Exception.Message -match 'missing required key' }
        Assert-Condition $rejected 'Incomplete report context accepted.'
        $directory = Join-Path $tempDirectory 'new-directory'
        $path = Export-InstallerTechnicalReport -DefaultDirectory $tempDirectory -DestinationPath ('"' + $directory + '"') -Context $context -Events @()
        Assert-Condition ((Test-Path -LiteralPath $path -PathType Leaf) -and (Split-Path -Parent $path) -eq $directory) 'Quoted new report directory failed.'
    }
    Invoke-Check 'report redacts paths, URL credentials, queries, and controls' {
        $events = @([pscustomobject]@{
            Timestamp = [datetimeoffset]$timestamp; State = 'Failed'
            Message = 'C:\Users\Example\log C:\Temp\file https://user:DEMO_PASSWORD@example.invalid/file.exe?token=DEMO_TOKEN#DEMO_FRAGMENT' + [char]27 + '[31m'
        }, [pscustomobject]@{
            Timestamp = [datetimeoffset]$timestamp; State = 'Failed'
            Message = 'ftp://user:DEMO_FTP_PASSWORD@example.invalid/file'
        }, [pscustomobject]@{
            Timestamp = [datetimeoffset]$timestamp; State = 'Failed'
            Message = 'https://user:DEMO PASSWORD@example.invalid/file.exe?token=DEMO QUERY'
        })
        $path = Export-InstallerTechnicalReport -DefaultDirectory $tempDirectory -DestinationPath (Join-Path $tempDirectory 'private.txt') -Context $context -Events $events
        $text = [IO.File]::ReadAllText($path)
        Assert-Condition ($text -notmatch 'DEMO|PASSWORD|QUERY|C:\\Users\\Example|C:\\Temp') 'Private report data leaked.'
        Assert-Condition ($text.Contains('%USERPROFILE%') -and $text.Contains('%TEMP%')) 'Path normalization lost.'
        Assert-Condition (-not $text.Contains([string][char]27)) 'Terminal escape leaked into report.'
    }
    Invoke-Check 'default filename collision permits another destination' {
        $defaultPath = Resolve-InstallerReportPath -DefaultDirectory $tempDirectory -Timestamp $timestamp
        Set-Content -LiteralPath $defaultPath -Value 'existing'
        $chosenPath = Join-Path $tempDirectory 'chosen.txt'
        $result = Invoke-InstallerCompletionPrompt @completion -KeyProvider (Get-InputProvider @('R', 'x')) -InputProvider (Get-InputProvider @($chosenPath)) -ReportExporter { param($path) $path } 6>$null
        Assert-Condition ($result.ReportSaved -and $result.ReportPath -eq $chosenPath) 'Could not choose alternate report.'
    }
    Invoke-Check 'report export failure retries and any other key exits' {
        $attempts = @{ Count = 0 }
        $exporter = { param($path) $attempts.Count++; if ($attempts.Count -eq 1) { throw 'Synthetic write failure' }; $path }.GetNewClosure()
        $chosenPath = Join-Path $tempDirectory 'retry.txt'
        $result = Invoke-InstallerCompletionPrompt @completion -KeyProvider (Get-InputProvider @('R', 'R', 'x')) -InputProvider (Get-InputProvider @($chosenPath, $chosenPath)) -ReportExporter $exporter 6>$null
        Assert-Condition ($result.ReportSaved -and $attempts.Count -eq 2) 'Report retry failed.'
        $result = Invoke-InstallerCompletionPrompt @completion -KeyProvider { 'x' } -InputProvider { throw 'Unexpected prompt' } -ReportExporter { throw 'Unexpected export' } 6>$null
        Assert-Condition (-not $result.ReportSaved) 'Any-key exit failed.'
    }
    Invoke-Check 'existing reports bypass export and failed exports can be abandoned' {
        $path = Join-Path $tempDirectory 'report.txt'
        $result = Invoke-InstallerCompletionPrompt @completion -ExistingReportPath $path -KeyProvider { 'R' } -InputProvider { throw 'Unexpected prompt' } -ReportExporter { throw 'Unexpected export' } 6>$null
        Assert-Condition ($result.ReportSaved -and $result.ReportPath -eq $path) 'Existing report prompted for another export.'
        $result = Invoke-InstallerCompletionPrompt @completion -KeyProvider (Get-InputProvider @('R', 'x')) -InputProvider { 'bad.csv' } -ReportExporter { throw 'Unexpected export' } 6>$null
        Assert-Condition (-not $result.ReportSaved -and $result.ReportError -match '\.txt extension') 'Report error or exit was lost.'
    }
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force
}
Write-Host ("ConsoleUI: {0} checks, {1} failures" -f $script:Checks, $script:Failures)
if ($script:Failures -gt 0) { exit 1 }
