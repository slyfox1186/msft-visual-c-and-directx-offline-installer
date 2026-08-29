Set-StrictMode -Version 2.0

$script:ConsoleWidth = 78
$script:StatusBadges = @{
    Download = '[DOWNLOAD]'
    Verify   = '[VERIFY  ]'
    Install  = '[INSTALL ]'
    Info     = '[INFO    ]'
    Ok       = '[OK      ]'
    Restart  = '[RESTART ]'
    Failed   = '[FAILED  ]'
    Cleanup  = '[CLEANUP ]'
    Retained = '[RETAINED]'
}

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

    return [string]$script:StatusBadges[$State]
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
    Write-Host '  -h | -Help | --help         Show help without UAC or downloads'
    Write-Host ''
    Write-Host 'RULES' -ForegroundColor Cyan
    Write-Host '  * Separate multiple values with commas. Values are case-insensitive.'
    Write-Host '  * Architecture is automatic and cannot be overridden.'
    Write-Host '  * Explicit .NET channels must still be supported by Microsoft.'
    Write-Host '  * .NET resolves the latest stable SDK in each selected supported channel.'
    Write-Host '  * Visual C++ v14 tracks Microsoft''s latest supported release.'
    Write-Host '  * Legacy Visual C++ and DirectX packages are final fixed releases.'
    Write-Host '  * Microsoft progress windows may appear; they require no clicks.'
    Write-Host '  * Packages never restart Windows automatically.'
    Write-Host '  * Downloads are removed by default, including after failures.'
    Write-Host ''
    Write-Host 'EXAMPLES' -ForegroundColor Cyan
    Write-Host '  .\Install.ps1'
    Write-Host '  .\Install.ps1 -Components DotNet,DirectX -DotNetChannels 8.0,10.0'
    Write-Host '  .\Install.ps1 -Components VisualCpp -VisualCppVersions 2013,v14'
    Write-Host '  .\Install.ps1 -ExcludeComponents DirectX -KeepDownloads'
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
    Write-InstallerPackageChoice -Key 1 -Enabled ([bool]$SelectedComponents.DotNet) -Label '.NET SDKs' -Detail 'Latest stable SDK in every selected supported channel'
    Write-Host ''
    Write-InstallerPackageChoice -Key 2 -Enabled ([bool]$SelectedComponents.VisualCpp) -Label 'Visual C++ Redistributables' -Detail 'Latest v14 plus final legacy releases (2005-2013)'
    Write-Host ''
    Write-InstallerPackageChoice -Key 3 -Enabled ([bool]$SelectedComponents.DirectX) -Label 'DirectX Legacy Runtime' -Detail 'Final Microsoft June 2010 release'
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
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [int]$DotNetPackageCount,

        [Parameter(Mandatory = $true)]
        [int]$VisualCppPackageCount,

        [Parameter(Mandatory = $true)]
        [bool]$DirectXSelected
    )

    $powerShellDisplay = $PowerShellVersion
    if (-not [string]::IsNullOrWhiteSpace($PowerShellEdition)) {
        $powerShellDisplay = "$PowerShellVersion ($PowerShellEdition)"
    }
    Write-InstallerStatus -State Info -Message "Windows architecture: $Architecture | PowerShell: $powerShellDisplay"
    Write-InstallerStatus -State Info -Message "curl: $CurlVersion"
    Write-InstallerStatus -State Info -Message ("Plan: {0}" -f (Format-InstallerPlan -DotNetPackageCount $DotNetPackageCount -VisualCppPackageCount $VisualCppPackageCount -DirectXSelected $DirectXSelected))
    Write-InstallerStatus -State Info -Message "Temporary workspace: $WorkspacePath"
    $trustControls = @('HTTPS-restricted Microsoft downloads')
    if ($DotNetPackageCount -gt 0) { $trustControls += 'SHA-512 metadata' }
    if ($VisualCppPackageCount -gt 0 -or $DirectXSelected) { $trustControls += 'Microsoft Authenticode signatures' }
    Write-InstallerStatus -State Info -Message ("Trust: {0}" -f ($trustControls -join ' | '))
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

    Write-Host ''
    Write-Host ('-' * $script:ConsoleWidth) -ForegroundColor DarkGray
    Write-Host ('  PHASE {0}/{1}  {2}' -f $Number, $Total, $Title.ToUpperInvariant()) -ForegroundColor Cyan
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

    $timestamp = [datetime]::Now.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $prefix = '[{0}] {1} ' -f $timestamp, (Get-InstallerStatusBadge -State $State)
    Write-InstallerWrappedLine -Prefix $prefix -Text $Message -Color (Get-InstallerStatusColor -State $State)
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
    'Get-InstallerStatusBadge',
    'Read-InstallerSelection',
    'Write-InstallerBanner',
    'Write-InstallerHelp',
    'Write-InstallerSection',
    'Write-InstallerStatus',
    'Write-InstallerSummary',
    'Write-InstallerSystemSummary'
)
