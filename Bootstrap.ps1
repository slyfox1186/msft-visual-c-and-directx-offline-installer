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
    [string]$Components = 'All',

    [AllowEmptyString()]
    [string]$ExcludeComponents = '',

    [string]$DotNetChannels = 'All',

    [string]$VisualCppVersions = 'All',

    [switch]$KeepDownloads,

    [Alias('h', 'Help')]
    [switch]$ShowHelp,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$startUri = 'https://raw.githubusercontent.com/slyfox1186/msft-visual-c-and-directx-offline-installer/main/Start.ps1'
$startHostPattern = '^raw\.githubusercontent\.com$'
$temporaryStartPattern = '^msri-start-[a-f0-9]{32}\.ps1$'
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

try {
    Write-Host '[INFO    ] Bootstrap.ps1 is retained for compatibility; Start.ps1 is the current launcher.' -ForegroundColor Yellow

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

    $powershellExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $powershellExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    $childArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $startPath),
        '-Components', ('"{0}"' -f $Components),
        '-DotNetChannels', ('"{0}"' -f $DotNetChannels),
        '-VisualCppVersions', ('"{0}"' -f $VisualCppVersions)
    )
    if (-not [string]::IsNullOrWhiteSpace($ExcludeComponents)) {
        $childArguments += @('-ExcludeComponents', ('"{0}"' -f $ExcludeComponents))
    }
    if ($KeepDownloads) { $childArguments += '-KeepDownloads' }
    if ($ShowHelp) { $childArguments += '-ShowHelp' }
    if ($null -ne $RemainingArguments -and $RemainingArguments.Count -gt 0) {
        $childArguments += $RemainingArguments
    }

    $childProcess = Start-Process -FilePath $powershellExecutable -ArgumentList $childArguments -Wait -PassThru -ErrorAction Stop
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
