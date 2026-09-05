#Requires -Version 5.1

<#
.SYNOPSIS
Downloads and runs the current Microsoft Runtime Installer source from GitHub.

.DESCRIPTION
Designed for the detached curl launcher and compatible with legacy streaming,
this script resolves one GitHub commit, downloads each required source file
individually over HTTPS into a protected temporary workspace, opens the
interactive selector when no package options were supplied, propagates the
installer exit code, and removes source files.
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

    [Alias('h', 'Help')]
    [switch]$ShowHelp,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

function Invoke-MicrosoftRuntimeLauncher {
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

        [switch]$ShowHelp,

        [string[]]$RemainingArguments,

        [Parameter(Mandatory = $true)]
        [Collections.IDictionary]$OriginalBoundParameters
    )

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$selectionOptionsWereBound = @(
    @('Components', 'ExcludeComponents', 'DotNetChannels', 'VisualCppVersions') |
        Where-Object { $OriginalBoundParameters.ContainsKey($_) }
)

$repositoryOwner = 'slyfox1186'
$repositoryName = 'msft-visual-c-and-directx-offline-installer'
$repositoryRefName = 'refs/heads/main'
$repositoryRefUri = 'https://api.github.com/repos/slyfox1186/msft-visual-c-and-directx-offline-installer/git/ref/heads/main'
$githubApiHost = 'api.github.com'
$githubApiVersion = '2026-03-10'
$githubRawHost = 'raw.githubusercontent.com'
$commitShaPattern = '\A[0-9a-f]{40}\z'
$requiredSourceFiles = @(
    'Install.ps1',
    'src/ConsoleUI.psm1',
    'src/RuntimeInstaller.psm1',
    'config/packages.psd1'
)
$launcherLeafPattern = '\Amsft-runtime-launcher-[a-f0-9]{32}\z'
# Dynamic source has no PSCommandPath in both detached and streamed launches,
# so the actual input handle determines whether a child can read the keyboard.
$launcherInputIsRedirected = [Console]::IsInputRedirected
$downloadedLauncherPath = Join-Path ([IO.Path]::GetTempPath()) 'msri.ps1'
$shouldDeleteSelf = -not [string]::IsNullOrWhiteSpace($PSCommandPath) -and
    [string]::Equals([IO.Path]::GetFullPath($PSCommandPath), [IO.Path]::GetFullPath($downloadedLauncherPath), [StringComparison]::OrdinalIgnoreCase)

function Get-LauncherStatusBadge {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'DOWNLOAD', 'OK', 'FAILED', 'CLEANUP')]
        [string]$State
    )

    $badgeWidth = 8
    $totalPadding = $badgeWidth - $State.Length
    $leftPadding = [math]::Floor($totalPadding / 2)
    $rightPadding = $totalPadding - $leftPadding

    return '[' + (' ' * $leftPadding) + $State + (' ' * $rightPadding) + ']'
}

function Write-LauncherStatus {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'DOWNLOAD', 'OK', 'FAILED', 'CLEANUP')]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $color = [ConsoleColor]::Cyan
    if ($State -eq 'OK') { $color = [ConsoleColor]::Green }
    if ($State -eq 'FAILED') { $color = [ConsoleColor]::Red }
    if ($State -eq 'CLEANUP') { $color = [ConsoleColor]::DarkCyan }
    $timestamp = [datetime]::Now.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $prefix = '[{0}] {1} ' -f $timestamp, (Get-LauncherStatusBadge -State $State)
    $continuationPrefix = ' ' * $prefix.Length
    $currentPrefix = $prefix
    $remainingMessage = $Message.Trim()
    if ($remainingMessage.Length -eq 0) {
        Write-Host $prefix -ForegroundColor $color
        return
    }

    while ($remainingMessage.Length -gt 0) {
        $availableWidth = 78 - $currentPrefix.Length
        if ($remainingMessage.Length -le $availableWidth) {
            $lineText = $remainingMessage
            $remainingMessage = ''
        }
        else {
            $breakPosition = $remainingMessage.LastIndexOf(' ', $availableWidth)
            if ($breakPosition -le 0) { $breakPosition = $availableWidth }
            $lineText = $remainingMessage.Substring(0, $breakPosition).TrimEnd()
            $remainingMessage = $remainingMessage.Substring($breakPosition).TrimStart()
        }
        Write-Host ($currentPrefix + $lineText) -ForegroundColor $color
        $currentPrefix = $continuationPrefix
    }
}

function Get-LauncherConsoleWidth {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    # Mirrors ConsoleUI.psm1's policy so launcher and installer screens agree on
    # one width: 78 when output is redirected, otherwise the live console width
    # bounded to the supported 72 through 110 range.
    $width = 78
    try {
        if (-not [Console]::IsOutputRedirected -and [Console]::WindowWidth -gt 1) {
            $width = [Console]::WindowWidth - 1
        }
    }
    catch {
        $width = 78
    }

    return [math]::Min(110, [math]::Max(72, $width))
}

function Write-LauncherWrappedLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 110)]
        [int]$Width,

        [ConsoleColor]$PrefixColor = [ConsoleColor]::White,

        [ConsoleColor]$TextColor = [ConsoleColor]::Gray
    )

    # The prefix doubles as the hanging indent, so a wrapped option description
    # or note stays inside the column its first line started in.
    $continuationPrefix = ' ' * $Prefix.Length
    $remainingText = $Text.Trim()
    $firstLine = $true
    while ($remainingText.Length -gt 0) {
        $availableWidth = $Width - $Prefix.Length
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
            Write-Host $Prefix -NoNewline -ForegroundColor $PrefixColor
            $firstLine = $false
        }
        else {
            Write-Host $continuationPrefix -NoNewline
        }
        Write-Host $lineText -ForegroundColor $TextColor
    }
}

function Write-LauncherHelp {
    [CmdletBinding()]
    param()

    # The launcher is standalone by design, so it repeats the installer's visual
    # language locally instead of importing ConsoleUI.psm1: '=' closes the
    # screen, an inset '-' opens a group, and columns are computed, not counted.
    $width = Get-LauncherConsoleWidth
    $indent = '  '
    $columnGap = 2
    $screenRule = '=' * $width
    $groupRule = $indent + ('-' * [math]::Max(1, ($width - (2 * $indent.Length))))
    $options = @(
        @{ Term = '-Components <list>'; Text = 'All (default), DotNet, VisualCpp, DirectX' },
        @{ Term = '-ExcludeComponents <list>'; Text = 'Remove component groups from the enabled set' },
        @{ Term = '-DotNetChannels <list>'; Text = 'All, or supported channels such as 8.0,10.0' },
        @{ Term = '-VisualCppVersions <list>'; Text = 'All, 2005, 2008, 2010, 2012, 2013, or v14' },
        @{ Term = '-KeepDownloads'; Text = 'Keep the Microsoft installer workspace' },
        @{ Term = '-ReportPath <path>'; Text = 'Write a UTF-8 .txt diagnostic report' },
        @{ Term = '-h | -Help | --help'; Text = 'Show help without UAC or downloads' }
    )
    $notes = @(
        'With no selection options, an interactive package menu opens.',
        'Explicit package options bypass the menu for automation.',
        '.NET resolves the latest stable SDK in each selected supported channel.',
        'Visual C++ v14 tracks Microsoft''s latest supported release.',
        'Legacy Visual C++ and DirectX packages are final fixed releases.',
        'Every Microsoft package source is resolved when the run starts.',
        'Launcher support files are fetched individually and are always temporary.',
        'KeepDownloads applies only to Microsoft metadata and installer packages.',
        'PowerShell 7 is preferred when pwsh.exe is in PATH; 5.1 is the fallback.'
    )

    $termWidth = 0
    foreach ($option in $options) {
        $termLength = ([string]$option.Term).Length
        if ($termLength -gt $termWidth) { $termWidth = $termLength }
    }
    $termWidth += $columnGap

    Write-Host ''
    Write-Host $screenRule -ForegroundColor Cyan
    Write-Host ($indent + 'MICROSOFT RUNTIME INSTALLER - CURL LAUNCHER') -ForegroundColor White
    Write-Host $screenRule -ForegroundColor Cyan
    Write-Host ''
    Write-Host ($indent + 'USAGE') -ForegroundColor Cyan
    Write-Host $groupRule -ForegroundColor DarkGray
    Write-Host ($indent + 'Start.ps1 [options]') -ForegroundColor Gray
    Write-Host ''
    Write-Host ($indent + 'OPTIONS') -ForegroundColor Cyan
    Write-Host $groupRule -ForegroundColor DarkGray
    foreach ($option in $options) {
        Write-LauncherWrappedLine -Prefix ($indent + ([string]$option.Term).PadRight($termWidth)) -Text ([string]$option.Text) -Width $width -PrefixColor White -TextColor Gray
    }
    Write-Host ''
    Write-Host ($indent + 'NOTES') -ForegroundColor Cyan
    Write-Host $groupRule -ForegroundColor DarkGray
    foreach ($note in $notes) {
        Write-LauncherWrappedLine -Prefix ($indent + '* ') -Text $note -Width $width -PrefixColor DarkGray -TextColor Gray
    }
    Write-Host ''
}

function Test-AllowedGitHubUri {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)]
        [ValidateSet('api.github.com', 'raw.githubusercontent.com')]
        [string]$ExpectedHost,
        [Parameter(Mandatory = $true)][string]$ExpectedAbsolutePath
    )

    try {
        $parsedUri = [uri]$Uri
        return $parsedUri.IsAbsoluteUri -and
            $parsedUri.Scheme -ceq 'https' -and
            $parsedUri.Port -eq 443 -and
            [string]::IsNullOrEmpty($parsedUri.UserInfo) -and
            [string]::Equals($parsedUri.DnsSafeHost, $ExpectedHost, [StringComparison]::OrdinalIgnoreCase) -and
            $parsedUri.AbsolutePath -ceq $ExpectedAbsolutePath -and
            [string]::IsNullOrEmpty($parsedUri.Query) -and
            [string]::IsNullOrEmpty($parsedUri.Fragment)
    }
    catch {
        return $false
    }
}

function Test-SafeLauncherWorkspace {
    param([Parameter(Mandatory = $true)][string]$WorkspacePath)

    try {
        $workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        return [string]::Equals((Split-Path -Parent $workspace), $temp, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $workspace) -match $launcherLeafPattern
    }
    catch {
        return $false
    }
}

function Invoke-GitHubSourceDownload {
    [CmdletBinding()]
    [OutputType([IO.FileInfo])]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('api.github.com', 'raw.githubusercontent.com')]
        [string]$ExpectedHost,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $parsedUri = [uri]$Uri
    if (-not (Test-AllowedGitHubUri -Uri $Uri -ExpectedHost $ExpectedHost -ExpectedAbsolutePath $parsedUri.AbsolutePath)) {
        throw "Rejected GitHub source URL: $Uri"
    }

    $fullWorkspacePath = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullDestinationPath = [IO.Path]::GetFullPath($DestinationPath)
    $comparison = [StringComparison]::OrdinalIgnoreCase
    $workspacePrefix = $fullWorkspacePath + [IO.Path]::DirectorySeparatorChar
    if (-not $fullDestinationPath.StartsWith($workspacePrefix, $comparison)) {
        throw "Refusing a GitHub download outside the launcher workspace: $fullDestinationPath"
    }
    $destinationDirectory = Split-Path -Parent $fullDestinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        throw "GitHub download directory does not exist: $destinationDirectory"
    }
    if (Test-Path -LiteralPath $fullDestinationPath) {
        throw "Refusing to overwrite an existing GitHub source file: $fullDestinationPath"
    }

    $curlExecutable = Get-PreferredCurlExecutable
    $curlArguments = @(
        '--fail', '--location', '--max-redirs', '10',
        '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2',
        '--retry', '4', '--retry-delay', '2', '--retry-connrefused',
        '--connect-timeout', '30', '--max-time', '120', '--silent',
        '--show-error', '--output', $fullDestinationPath,
        '--write-out', '%{url_effective}', '--url', $parsedUri.AbsoluteUri
    )
    if ($ExpectedHost -ceq $githubApiHost) {
        $curlArguments = @(
            '--header', 'Accept: application/vnd.github+json',
            '--header', "X-GitHub-Api-Version: $githubApiVersion"
        ) + $curlArguments
    }

    Write-LauncherStatus -State DOWNLOAD -Message "$DisplayName ..."
    try {
        $effectiveUriText = (& $curlExecutable @curlArguments | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe failed with exit code $LASTEXITCODE while downloading $DisplayName."
        }
        if (-not (Test-AllowedGitHubUri -Uri $effectiveUriText -ExpectedHost $ExpectedHost -ExpectedAbsolutePath $parsedUri.AbsolutePath)) {
            throw "Rejected effective GitHub URL for ${DisplayName}: $effectiveUriText"
        }

        $downloadedFile = Get-Item -LiteralPath $fullDestinationPath -Force -ErrorAction Stop
        if ($downloadedFile.PSIsContainer -or $downloadedFile.Length -le 0) {
            throw "GitHub did not return a nonempty regular file for $DisplayName."
        }
        Write-LauncherStatus -State OK -Message ("{0} downloaded ({1:N0} bytes)." -f $DisplayName, $downloadedFile.Length)
        return $downloadedFile
    }
    catch {
        Remove-Item -LiteralPath $fullDestinationPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-GitHubCommitSha {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath
    )

    $revisionPath = Join-Path ([IO.Path]::GetFullPath($WorkspacePath)) 'github-ref.json'
    $null = Invoke-GitHubSourceDownload -Uri $repositoryRefUri -DestinationPath $revisionPath -WorkspacePath $WorkspacePath -ExpectedHost $githubApiHost -DisplayName 'Resolving the current GitHub revision'
    $revision = Get-Content -LiteralPath $revisionPath -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    $refProperty = $revision.PSObject.Properties['ref']
    if ($null -eq $refProperty -or [string]$refProperty.Value -cne $repositoryRefName) {
        throw "GitHub revision metadata returned an unexpected ref; expected $repositoryRefName."
    }
    $objectProperty = $revision.PSObject.Properties['object']
    if ($null -eq $objectProperty -or $null -eq $objectProperty.Value) {
        throw 'GitHub revision metadata is missing the object property.'
    }
    $typeProperty = $objectProperty.Value.PSObject.Properties['type']
    if ($null -eq $typeProperty -or [string]$typeProperty.Value -cne 'commit') {
        throw 'GitHub revision metadata returned an unexpected object type; expected commit.'
    }
    $shaProperty = $objectProperty.Value.PSObject.Properties['sha']
    if ($null -eq $shaProperty) {
        throw 'GitHub revision metadata is missing object.sha.'
    }
    $commitSha = [string]$shaProperty.Value
    if ($commitSha -notmatch $commitShaPattern) {
        throw "GitHub returned an invalid commit SHA: $commitSha"
    }
    return $commitSha
}

function Assert-PowerShellSourceSyntax {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )

    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        [IO.Path]::GetFullPath($LiteralPath),
        [ref]$tokens,
        [ref]$parseErrors
    )
    $errors = @($parseErrors)
    if ($errors.Count -gt 0) {
        throw "Downloaded PowerShell source failed syntax validation: $LiteralPath ($($errors[0].Message))"
    }
}

function Assert-SafeOptionValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [switch]$AllowEmpty
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($AllowEmpty) { return }
        throw "$Name cannot be empty."
    }
    if ($Value -notmatch $Pattern) {
        throw "$Name contains an unsupported value or character: $Value"
    }
}

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

function Get-PreferredCurlExecutable {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Windows 10 1803 and later ship curl.exe in System32 as an operating system
    # component. Prefer it so a writable PATH entry ahead of System32 cannot
    # substitute the downloader that enforces the HTTPS-only protocol and
    # redirect policy, TLS floor, and effective-URL reporting used below.
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $systemCurlPath = Join-Path $env:SystemRoot 'System32\curl.exe'
        if (Test-Path -LiteralPath $systemCurlPath -PathType Leaf) {
            return [IO.Path]::GetFullPath($systemCurlPath)
        }
    }

    $curlCommand = Get-Command -Name 'curl.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $curlCommand) {
        throw 'curl.exe is required but was not found in the Windows system directory or in PATH.'
    }

    return $curlCommand.Source
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

if ($null -ne $RemainingArguments -and $RemainingArguments.Count -gt 0) {
    if ($RemainingArguments.Count -eq 1 -and $RemainingArguments[0] -ceq '--help') {
        $ShowHelp = $true
    }
    else {
        Write-Host "Unknown argument(s): $($RemainingArguments -join ' ')" -ForegroundColor Red
        exit 1
    }
}

if ($ShowHelp) {
    Write-LauncherHelp
    if ($shouldDeleteSelf) {
        try {
            Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction Stop
        }
        catch {
            Write-LauncherStatus -State FAILED -Message "Downloaded launcher cleanup failed: $($_.Exception.Message)"
            exit 1
        }
    }
    exit 0
}

$componentText = @($Components) -join ','
$excludedComponentText = @($ExcludeComponents) -join ','
$dotNetChannelText = ConvertTo-DotNetChannelText -Value $DotNetChannels
$visualCppVersionText = @($VisualCppVersions) -join ','

$componentPattern = '(?i)\A(?:All|DotNet|VisualCpp|DirectX)(?:[ \t]*,[ \t]*(?:All|DotNet|VisualCpp|DirectX))*\z'
$dotNetPattern = '(?i)\A(?:All|\d+\.\d+)(?:[ \t]*,[ \t]*(?:All|\d+\.\d+))*\z'
$visualCppPattern = '(?i)\A(?:All|2005|2008|2010|2012|2013|v14)(?:[ \t]*,[ \t]*(?:All|2005|2008|2010|2012|2013|v14))*\z'
try {
    Assert-SafeOptionValue -Name 'Components' -Value $componentText -Pattern $componentPattern
    Assert-SafeOptionValue -Name 'ExcludeComponents' -Value $excludedComponentText -Pattern $componentPattern -AllowEmpty
    Assert-SafeOptionValue -Name 'DotNetChannels' -Value $dotNetChannelText -Pattern $dotNetPattern
    Assert-SafeOptionValue -Name 'VisualCppVersions' -Value $visualCppVersionText -Pattern $visualCppPattern
    if (-not [string]::IsNullOrWhiteSpace($ReportPath) -and $ReportPath -match '[\x00-\x1f"]') {
        throw 'ReportPath contains a control character or quotation mark.'
    }
}
catch {
    Write-LauncherStatus -State FAILED -Message "Invalid launcher options: $($_.Exception.Message)"
    Write-Host 'Run Start.ps1 -Help for supported options.'
    exit 1
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This launcher supports Windows only. Help is available with -Help.'
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    try {
        $ReportPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ReportPath))
    }
    catch {
        throw "Invalid technical report path: $($_.Exception.Message)"
    }
}

$normalizedComponents = $componentText -replace '\s', ''
$normalizedExclusions = $excludedComponentText -replace '\s', ''
$normalizedDotNetChannels = $dotNetChannelText -replace '\s', ''
$normalizedVisualCppVersions = $visualCppVersionText -replace '\s', ''
$workspacePath = Join-Path ([IO.Path]::GetTempPath()) ('msft-runtime-launcher-{0}' -f [guid]::NewGuid().ToString('N'))
$finalExitCode = 1

try {
    if (-not (Test-SafeLauncherWorkspace -WorkspacePath $workspacePath)) {
        throw "Generated an unsafe launcher workspace: $workspacePath"
    }
    $null = New-Item -Path $workspacePath -ItemType Directory -ErrorAction Stop
    $sourceRoot = Join-Path $workspacePath 'source'
    $null = New-Item -Path $sourceRoot -ItemType Directory -ErrorAction Stop

    $commitSha = Get-GitHubCommitSha -WorkspacePath $workspacePath
    Write-LauncherStatus -State OK -Message ("Pinned source revision: {0}" -f $commitSha.Substring(0, 12))

    $downloadedSourcePaths = @{}
    foreach ($relativePath in $requiredSourceFiles) {
        $localRelativePath = $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $destinationPath = Join-Path $sourceRoot $localRelativePath
        $destinationDirectory = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
            $null = New-Item -Path $destinationDirectory -ItemType Directory -Force -ErrorAction Stop
        }

        $rawUri = 'https://raw.githubusercontent.com/{0}/{1}/{2}/{3}' -f $repositoryOwner, $repositoryName, $commitSha, $relativePath
        $downloadedFile = Invoke-GitHubSourceDownload -Uri $rawUri -DestinationPath $destinationPath -WorkspacePath $workspacePath -ExpectedHost $githubRawHost -DisplayName $relativePath
        Assert-PowerShellSourceSyntax -LiteralPath $downloadedFile.FullName
        $downloadedSourcePaths[$relativePath] = $downloadedFile.FullName
    }
    if ($downloadedSourcePaths.Count -ne $requiredSourceFiles.Count) {
        throw "Expected $($requiredSourceFiles.Count) source files; downloaded $($downloadedSourcePaths.Count)."
    }
    $installScriptPath = [string]$downloadedSourcePaths['Install.ps1']
    if ([string]::IsNullOrWhiteSpace($installScriptPath)) {
        throw 'The commit-pinned source set did not contain Install.ps1.'
    }
    Write-LauncherStatus -State OK -Message 'Individual source files passed syntax validation.'

    $powershellExecutable = Get-PreferredPowerShellExecutable
    $childArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (ConvertTo-NativeQuotedArgument -Value $installScriptPath)
    )
    if ($selectionOptionsWereBound.Count -gt 0) {
        $childArguments += @(
            '-Components', ('"{0}"' -f $normalizedComponents),
            '-DotNetChannels', ('"{0}"' -f $normalizedDotNetChannels),
            '-VisualCppVersions', ('"{0}"' -f $normalizedVisualCppVersions)
        )
        if (-not [string]::IsNullOrWhiteSpace($normalizedExclusions)) {
            $childArguments += @('-ExcludeComponents', ('"{0}"' -f $normalizedExclusions))
        }
    }
    if ($KeepDownloads) { $childArguments += '-KeepDownloads' }
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        $childArguments += @('-ReportPath', (ConvertTo-NativeQuotedArgument -Value $ReportPath))
    }
    $childArguments += @('-SourceRevision', $commitSha)

    $powerShellHostName = [IO.Path]::GetFileName($powershellExecutable)
    Write-LauncherStatus -State INFO -Message "Starting the validated source with $powerShellHostName ..."
    $startParameters = @{
        FilePath     = $powershellExecutable
        ArgumentList = $childArguments
        Wait         = $true
        PassThru     = $true
        ErrorAction  = 'Stop'
    }
    if ($selectionOptionsWereBound.Count -gt 0 -or -not $launcherInputIsRedirected) {
        $startParameters.NoNewWindow = $true
    }
    else {
        $startParameters.WindowStyle = 'Maximized'
    }
    $childProcess = Start-Process @startParameters
    if ($childProcess.ExitCode -notin @(0, 1, 2, 3010)) {
        throw "Installer returned unexpected exit code $($childProcess.ExitCode)."
    }
    $finalExitCode = $childProcess.ExitCode
    if ($finalExitCode -eq 0) {
        Write-LauncherStatus -State OK -Message 'Installer completed successfully.'
    }
    elseif ($finalExitCode -eq 2) {
        Write-LauncherStatus -State INFO -Message 'Installation was cancelled before any packages were downloaded.'
    }
    elseif ($finalExitCode -eq 3010) {
        Write-LauncherStatus -State INFO -Message 'Installer completed. Restart Windows manually to finish.'
    }
    else {
        Write-LauncherStatus -State FAILED -Message 'Installer stopped with an error. Review its status output.'
    }
}
catch {
    Write-LauncherStatus -State FAILED -Message $_.Exception.Message
    $finalExitCode = 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($workspacePath)) {
        try {
            if (-not (Test-SafeLauncherWorkspace -WorkspacePath $workspacePath)) {
                throw "Refusing to remove unsafe launcher workspace: $workspacePath"
            }
            if (Test-Path -LiteralPath $workspacePath) {
                $workspaceItem = Get-Item -LiteralPath $workspacePath -Force -ErrorAction Stop
                if (($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing to remove a reparse-point launcher workspace: $workspacePath"
                }
                Remove-Item -LiteralPath $workspacePath -Recurse -Force -ErrorAction Stop
                Write-LauncherStatus -State CLEANUP -Message 'Launcher source files removed.'
            }
        }
        catch {
            Write-LauncherStatus -State FAILED -Message "Launcher cleanup failed: $($_.Exception.Message)"
            $finalExitCode = 1
        }
    }

    if ($shouldDeleteSelf) {
        try {
            Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction Stop
        }
        catch {
            Write-LauncherStatus -State FAILED -Message "Downloaded launcher cleanup failed: $($_.Exception.Message)"
            $finalExitCode = 1
        }
    }
}

exit $finalExitCode
}

Invoke-MicrosoftRuntimeLauncher -Components $Components -ExcludeComponents $ExcludeComponents -DotNetChannels $DotNetChannels -VisualCppVersions $VisualCppVersions -KeepDownloads:$KeepDownloads -ReportPath $ReportPath -ShowHelp:$ShowHelp -RemainingArguments $RemainingArguments -OriginalBoundParameters $PSBoundParameters
