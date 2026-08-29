#Requires -Version 5.1

<#
.SYNOPSIS
Forwards legacy Bootstrap.ps1 invocations to the canonical Start.ps1 launcher.

.DESCRIPTION
This compatibility entry point preserves previously published commands. New
commands should download Start.ps1 directly.
#>

[CmdletBinding()]
param(
    [string[]]$Components = 'All',

    [AllowEmptyString()]
    [string[]]$ExcludeComponents = '',

    [string[]]$DotNetChannels = 'All',

    [string[]]$VisualCppVersions = 'All',

    [switch]$KeepDownloads,

    [Alias('h', 'Help')]
    [switch]$ShowHelp,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$startUri = 'https://raw.githubusercontent.com/slyfox1186/msft-visual-c-and-directx-offline-installer/main/Start.ps1'
$startHostPattern = '\Araw\.githubusercontent\.com\z'
$temporaryStartPattern = '\Amsri-start-[a-f0-9]{32}\.ps1\z'
$temporaryStartPath = Join-Path ([IO.Path]::GetTempPath()) ('msri-start-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
$downloadedCompatibilityPath = Join-Path ([IO.Path]::GetTempPath()) 'msft-runtime-bootstrap.ps1'
$shouldDeleteSelf = -not [string]::IsNullOrWhiteSpace($PSCommandPath) -and
    [string]::Equals([IO.Path]::GetFullPath($PSCommandPath), [IO.Path]::GetFullPath($downloadedCompatibilityPath), [StringComparison]::OrdinalIgnoreCase)
$ownsTemporaryStart = $false
$finalExitCode = 1

function Test-AllowedStartUri {
    param([Parameter(Mandatory = $true)][string]$Uri)

    try {
        $parsedUri = [uri]$Uri
        return $parsedUri.IsAbsoluteUri -and
            $parsedUri.Scheme -ceq 'https' -and
            $parsedUri.Port -eq 443 -and
            [string]::IsNullOrEmpty($parsedUri.UserInfo) -and
            $parsedUri.DnsSafeHost -match $startHostPattern
    }
    catch {
        return $false
    }
}

function Test-SafeTemporaryStartPath {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    try {
        $fullPath = [IO.Path]::GetFullPath($LiteralPath)
        $tempPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        return [string]::Equals((Split-Path -Parent $fullPath), $tempPath, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $fullPath) -match $temporaryStartPattern
    }
    catch {
        return $false
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

function Get-PreferredPowerShellExecutable {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return (Get-Process -Id $PID -ErrorAction Stop).Path
    }

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

if ($null -ne $RemainingArguments -and $RemainingArguments.Count -gt 0) {
    if ($RemainingArguments.Count -eq 1 -and $RemainingArguments[0] -ceq '--help') {
        $ShowHelp = $true
    }
    else {
        Write-Host "[FAILED  ] Unknown argument(s): $($RemainingArguments -join ' ')" -ForegroundColor Red
        exit 1
    }
}

$selectionOptionsWereBound = @(
    @('Components', 'ExcludeComponents', 'DotNetChannels', 'VisualCppVersions') |
        Where-Object { $PSBoundParameters.ContainsKey($_) }
)
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
}
catch {
    Write-Host "[FAILED  ] Invalid compatibility options: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$normalizedComponents = $componentText -replace '\s', ''
$normalizedExclusions = $excludedComponentText -replace '\s', ''
$normalizedDotNetChannels = $dotNetChannelText -replace '\s', ''
$normalizedVisualCppVersions = $visualCppVersionText -replace '\s', ''

try {
    Write-Host '[INFO    ] Bootstrap.ps1 is a compatibility launcher.' -ForegroundColor Yellow
    Write-Host '[INFO    ] Start.ps1 is the current entry point.' -ForegroundColor Yellow

    $localStartPath = Join-Path $PSScriptRoot 'Start.ps1'
    if (Test-Path -LiteralPath $localStartPath -PathType Leaf) {
        $startPath = [IO.Path]::GetFullPath($localStartPath)
    }
    else {
        if (-not (Test-SafeTemporaryStartPath -LiteralPath $temporaryStartPath)) {
            throw "Generated an unsafe temporary Start.ps1 path: $temporaryStartPath"
        }
        if (-not (Test-AllowedStartUri -Uri $startUri)) {
            throw "Rejected Start.ps1 URL: $startUri"
        }

        $curlCommand = Get-Command -Name 'curl.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $curlArguments = @(
            '--fail', '--location', '--max-redirs', '10',
            '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2',
            '--retry', '4', '--retry-delay', '2', '--retry-connrefused',
            '--connect-timeout', '30', '--max-time', '120', '--silent',
            '--show-error', '--output', $temporaryStartPath,
            '--write-out', '%{url_effective}', '--url', $startUri
        )
        $effectiveUriText = (& $curlCommand.Source @curlArguments | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe failed with exit code $LASTEXITCODE while downloading Start.ps1."
        }
        if (-not (Test-AllowedStartUri -Uri $effectiveUriText)) {
            throw "Rejected effective Start.ps1 URL: $effectiveUriText"
        }
        $startFile = Get-Item -LiteralPath $temporaryStartPath -Force -ErrorAction Stop
        if ($startFile.PSIsContainer -or $startFile.Length -le 0) {
            throw 'Downloaded Start.ps1 is empty or is not a regular file.'
        }
        $startPath = $startFile.FullName
        $ownsTemporaryStart = $true
    }

    $powershellExecutable = Get-PreferredPowerShellExecutable
    $childArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $startPath)
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
    if ($ShowHelp) { $childArguments += '-ShowHelp' }

    $childProcess = Start-Process -FilePath $powershellExecutable -ArgumentList $childArguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
    $finalExitCode = $childProcess.ExitCode
}
catch {
    Write-Host "[FAILED  ] $($_.Exception.Message)" -ForegroundColor Red
    $finalExitCode = 1
}
finally {
    if ($ownsTemporaryStart -and -not [string]::IsNullOrWhiteSpace($temporaryStartPath)) {
        try {
            if (-not (Test-SafeTemporaryStartPath -LiteralPath $temporaryStartPath)) {
                throw "Refusing to remove unsafe temporary Start.ps1 path: $temporaryStartPath"
            }
            if (Test-Path -LiteralPath $temporaryStartPath) {
                $temporaryItem = Get-Item -LiteralPath $temporaryStartPath -Force -ErrorAction Stop
                if (($temporaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing to remove a reparse-point Start.ps1 path: $temporaryStartPath"
                }
                Remove-Item -LiteralPath $temporaryStartPath -Force -ErrorAction Stop
            }
        }
        catch {
            Write-Host "[FAILED  ] Compatibility cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
            $finalExitCode = 1
        }
    }

    if ($shouldDeleteSelf) {
        try {
            Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction Stop
        }
        catch {
            Write-Host "[FAILED  ] Downloaded compatibility launcher cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
            $finalExitCode = 1
        }
    }
}

exit $finalExitCode
