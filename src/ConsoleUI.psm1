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
    Write-Host ''
    Write-Host 'OPTIONS' -ForegroundColor Cyan
    Write-Host '  -Components <list>          All (default), DotNet, VisualCpp, DirectX'
    Write-Host '  -ExcludeComponents <list>   Remove component groups from the enabled set'
    Write-Host '  -DotNetChannels <list>      All, or supported channels such as 8.0,10.0'
    Write-Host '  -VisualCppVersions <list>   All, 2005, 2008, 2010, 2012, 2013, or v14'
    Write-Host '  -KeepDownloads              Keep verified Microsoft installers'
    Write-Host '  -h | -Help | --help         Show help without UAC or downloads'
    Write-Host ''
    Write-Host 'RULES' -ForegroundColor Cyan
    Write-Host '  * Separate multiple values with commas. Values are case-insensitive.'
    Write-Host '  * Architecture is automatic and cannot be overridden.'
    Write-Host '  * Explicit .NET channels must still be supported by Microsoft.'
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
    Write-Host '  3010  Completed successfully; restart Windows to finish'
}

function Write-InstallerSystemSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [string]$PowerShellVersion,

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

    Write-InstallerStatus -State Info -Message "Windows architecture: $Architecture | Windows PowerShell: $PowerShellVersion"
    Write-InstallerStatus -State Info -Message "curl: $CurlVersion"
    Write-InstallerStatus -State Info -Message ("Plan: {0}" -f (Format-InstallerPlan -DotNetPackageCount $DotNetPackageCount -VisualCppPackageCount $VisualCppPackageCount -DirectXSelected $DirectXSelected))
    Write-InstallerStatus -State Info -Message "Temporary workspace: $WorkspacePath"
    Write-InstallerStatus -State Info -Message 'Trust: HTTPS Microsoft hosts, SHA-512 metadata, and Microsoft Authenticode signatures'
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

    $timestamp = Get-Date -Format 'HH:mm:ss'
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
        Write-InstallerStatus -State Retained -Message "Verified downloads retained at: $RetainedWorkspacePath"
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
    'Write-InstallerBanner',
    'Write-InstallerHelp',
    'Write-InstallerSection',
    'Write-InstallerStatus',
    'Write-InstallerSummary',
    'Write-InstallerSystemSummary'
)
