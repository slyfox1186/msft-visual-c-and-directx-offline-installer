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
    $title = 'MICROSOFT RUNTIME INSTALLER'
    $subtitle = 'Secure downloads | Architecture-aware | Automatic cleanup'

    Write-Host ''
    Write-Host $topRule -ForegroundColor Cyan
    Write-Host ('| ' + $title.PadRight($script:ConsoleWidth - 4) + ' |') -ForegroundColor Cyan
    Write-Host ('| ' + $subtitle.PadRight($script:ConsoleWidth - 4) + ' |') -ForegroundColor DarkCyan
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
        [bool]$KeepDownloads
    )

    $dotNetState = if ($SelectedComponents.DotNet) { 'X' } else { ' ' }
    $visualCppState = if ($SelectedComponents.VisualCpp) { 'X' } else { ' ' }
    $directXState = if ($SelectedComponents.DirectX) { 'X' } else { ' ' }
    $keepState = if ($KeepDownloads) { 'X' } else { ' ' }
    $dotNetAction = if ($SelectedComponents.DotNet) { '>' } else { '-' }
    $visualCppAction = if ($SelectedComponents.VisualCpp) { '>' } else { '-' }
    $dotNetDetail = if (-not $SelectedComponents.DotNet) {
        'Enable [1] first'
    }
    elseif ($DotNetChannels.Trim() -ieq 'All') {
        'All supported (latest stable)'
    }
    else {
        $DotNetChannels
    }
    $visualCppDetail = if (-not $SelectedComponents.VisualCpp) {
        'Enable [2] first'
    }
    elseif ($VisualCppVersions.Trim() -ieq 'All') {
        'All release families'
    }
    else {
        $VisualCppVersions
    }

    Write-Host ''
    Write-Host ('-' * $script:ConsoleWidth) -ForegroundColor DarkGray
    Write-Host '  PACKAGE GROUPS' -ForegroundColor Cyan
    Write-Host ('-' * $script:ConsoleWidth) -ForegroundColor DarkGray
    Write-Host ("  [1] [{0}] {1,-30}{2}" -f $dotNetState, '.NET SDKs', 'Latest stable per supported channel')
    Write-Host ("  [2] [{0}] {1,-30}{2}" -f $visualCppState, 'Visual C++ Runtimes', 'Latest supported v14 + final legacy')
    Write-Host ("  [3] [{0}] {1,-30}{2}" -f $directXState, 'DirectX Legacy Runtimes', 'Final June 2010 release')
    Write-Host ''
    Write-Host '  VERSION FILTERS (OPTIONAL)' -ForegroundColor Cyan
    Write-Host ("  [4] [{0}] {1,-35}{2}" -f $dotNetAction, 'Choose .NET SDK channels', $dotNetDetail)
    Write-Host ("  [5] [{0}] {1,-35}{2}" -f $visualCppAction, 'Choose Visual C++ release families', $visualCppDetail)
    Write-Host ''
    Write-Host '  RELEASE RESOLUTION' -ForegroundColor Cyan
    Write-Host '  Dynamic: .NET -> latest stable per selected supported channel'
    Write-Host '           VC++ v14 -> latest supported Microsoft release'
    Write-Host '  Fixed:   final legacy VC++ (2005-2013) and DirectX June 2010 releases.'
    Write-Host ''
    Write-Host '  OTHER OPTIONS' -ForegroundColor Cyan
    Write-Host ("  [K] [{0}] Keep downloaded files" -f $keepState)
    Write-Host ''
    Write-Host '  1-3 toggle groups | 4-5 choose versions | K keeps downloads'
    Write-Host '  A selects all packages | ENTER installs | Q cancels'
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

function Read-InstallerSelection {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [scriptblock]$InputProvider = { param($Prompt) Read-Host -Prompt $Prompt },

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

    Write-InstallerBanner
    Write-InstallerStatus -State Info -Message 'Choose package groups and optional versions, then press ENTER.'

    while ($true) {
        Write-InstallerSelectionMenu -SelectedComponents $selectedComponents -DotNetChannels $dotNetChannels -VisualCppVersions $visualCppVersions -KeepDownloads $keepDownloads
        $rawChoice = & $InputProvider 'Selection'
        if ($null -eq $rawChoice) {
            throw 'Interactive input ended. Use explicit component switches for automation.'
        }
        $choice = ([string]$rawChoice).Trim()

        if ($choice.Length -eq 0) {
            $enabledCount = @($selectedComponents.Values | Where-Object { $_ }).Count
            if ($enabledCount -eq 0) {
                Write-InstallerStatus -State Failed -Message 'Select at least one package group before continuing.'
                continue
            }

            $components = @('DotNet', 'VisualCpp', 'DirectX') |
                Where-Object { $selectedComponents[$_] }
            return [pscustomobject]@{
                Components        = $components -join ','
                DotNetChannels    = if ($selectedComponents.DotNet) { $dotNetChannels } else { 'All' }
                VisualCppVersions = if ($selectedComponents.VisualCpp) { $visualCppVersions } else { 'All' }
                KeepDownloads     = $keepDownloads
                Cancelled         = $false
            }
        }

        switch ($choice.ToUpperInvariant()) {
            '1' { $selectedComponents.DotNet = -not $selectedComponents.DotNet; continue }
            '2' { $selectedComponents.VisualCpp = -not $selectedComponents.VisualCpp; continue }
            '3' { $selectedComponents.DirectX = -not $selectedComponents.DirectX; continue }
            '4' {
                if (-not $selectedComponents.DotNet) {
                    Write-InstallerStatus -State Info -Message 'Enable .NET SDKs before choosing SDK channels.'
                    continue
                }
                $rawChannels = & $InputProvider '.NET SDK channels (All or example: 8.0,10.0)'
                if ($null -eq $rawChannels) {
                    throw 'Interactive input ended while choosing .NET SDK channels.'
                }
                $candidate = ([string]$rawChannels).Trim() -replace '[ \t]', ''
                $channelPattern = '(?i)\A(?:All|\d+\.\d+)(?:,(?:\d+\.\d+))*\z'
                if (-not (Test-InstallerMenuSelection -Value $candidate -Pattern $channelPattern)) {
                    Write-InstallerStatus -State Failed -Message 'Use All or comma-separated SDK channels such as 8.0,10.0.'
                    continue
                }
                $dotNetChannels = $candidate
                continue
            }
            '5' {
                if (-not $selectedComponents.VisualCpp) {
                    Write-InstallerStatus -State Info -Message 'Enable Visual C++ before choosing release families.'
                    continue
                }
                $rawVersions = & $InputProvider 'Visual C++ release families (All or example: 2013,v14)'
                if ($null -eq $rawVersions) {
                    throw 'Interactive input ended while choosing Visual C++ release families.'
                }
                $candidate = ([string]$rawVersions).Trim() -replace '[ \t]', ''
                $versionPattern = '(?i)\A(?:All|2005|2008|2010|2012|2013|v14)(?:,(?:2005|2008|2010|2012|2013|v14))*\z'
                if (-not (Test-InstallerMenuSelection -Value $candidate -Pattern $versionPattern)) {
                    Write-InstallerStatus -State Failed -Message 'Use All or release families from 2005, 2008, 2010, 2012, 2013, and v14.'
                    continue
                }
                $visualCppVersions = $candidate
                continue
            }
            'A' {
                $selectedComponents.DotNet = $true
                $selectedComponents.VisualCpp = $true
                $selectedComponents.DirectX = $true
                $dotNetChannels = 'All'
                $visualCppVersions = 'All'
                continue
            }
            'K' { $keepDownloads = -not $keepDownloads; continue }
            'Q' {
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
                Write-InstallerStatus -State Failed -Message "Unknown selection '$choice'. Choose 1-5, A, K, ENTER, or Q."
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
