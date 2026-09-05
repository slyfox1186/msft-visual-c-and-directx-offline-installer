#Requires -Version 5.1
# Compatibility for published commands; all installation behavior lives in Start.ps1.
[CmdletBinding()]
param(
    [string[]]$Components = 'All',
    [AllowEmptyString()][string[]]$ExcludeComponents = '',
    [string[]]$DotNetChannels = 'All',
    [string[]]$VisualCppVersions = 'All',
    [switch]$KeepDownloads,
    [AllowEmptyString()][string]$ReportPath = '',
    [Alias('h', 'Help')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$options = @{}
foreach ($name in @('Components', 'ExcludeComponents', 'DotNetChannels', 'VisualCppVersions', 'KeepDownloads', 'ReportPath', 'ShowHelp', 'RemainingArguments')) {
    if ($PSBoundParameters.ContainsKey($name)) { $options[$name] = $PSBoundParameters[$name] }
}
$temporaryPath = ''
$exitCode = 1
try {
    $startPath = ''
    if ($PSScriptRoot) { $startPath = Join-Path $PSScriptRoot 'Start.ps1' }
    if (-not $startPath -or -not (Test-Path -LiteralPath $startPath -PathType Leaf)) {
        if ($null -ne $RemainingArguments -and $RemainingArguments.Count) {
            if ($RemainingArguments.Count -ne 1 -or $RemainingArguments[0] -cne '--help') { throw 'Unknown compatibility launcher argument.' }
            $ShowHelp = $true
        }
        if ($ShowHelp) {
            Write-Host @'
Bootstrap.ps1 forwards to Start.ps1. Supported options:
-Components All|DotNet|VisualCpp|DirectX  -ExcludeComponents <groups>
-DotNetChannels All|<channels>          -VisualCppVersions All|<families>
Visual C++ families: 2005, 2008, 2010, 2012, 2013, v14
-KeepDownloads  -ReportPath <file-or-folder>  -h|-Help|--help
Use comma-separated lists. No selection options opens the interactive menu.
'@
            $startPath = ''
            $exitCode = 0
        }
        else {
            if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This launcher supports Windows only.' }
            $uri = 'https://raw.githubusercontent.com/slyfox1186/msft-visual-c-and-directx-offline-installer/main/Start.ps1'
            $curlExecutable = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (-not (Test-Path -LiteralPath $curlExecutable -PathType Leaf)) {
                $curlExecutable = (Get-Command curl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
            }
            $startPath = Join-Path ([IO.Path]::GetTempPath()) ('msri-start-' + [guid]::NewGuid().ToString('N') + '.ps1')
            # Claim ownership before downloading so failed transfers are cleaned up too.
            $stream = [IO.File]::Open($startPath, [IO.FileMode]::CreateNew)
            $stream.Dispose()
            $temporaryPath = $startPath
            $effective = (& $curlExecutable --fail --location --max-redirs 10 --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 4 --retry-delay 2 --retry-connrefused --connect-timeout 30 --max-time 120 --silent --show-error --output $startPath --write-out '%{url_effective}' --url $uri | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $effective -cne $uri) { throw 'Start.ps1 download failed or redirected to an unexpected URL.' }
            if ((Get-Item -LiteralPath $startPath).Length -le 0) { throw 'Downloaded Start.ps1 is empty.' }
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($startPath, [ref]$null, [ref]$errors)
            if ($errors.Count) { throw 'Downloaded Start.ps1 failed syntax validation.' }
        }
    }
    if ($startPath) {
        & $startPath @options
        $exitCode = $LASTEXITCODE
        if ($exitCode -notin @(0, 1, 2, 3010)) { throw "Unexpected launcher exit code: $exitCode" }
    }
}
catch {
    Write-Host ('[ FAILED ] ' + ($_.Exception.Message -replace '[^\x20-\x7e]', ' ')) -ForegroundColor Red
    $exitCode = 1
}
finally {
    try {
        if ($temporaryPath) {
            $tempRoot = [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar)
            if ((Split-Path $temporaryPath -Parent) -ine $tempRoot -or
                (Split-Path $temporaryPath -Leaf) -cnotmatch '\Amsri-start-[a-f0-9]{32}\.ps1\z' -or
                ((Get-Item -LiteralPath $temporaryPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Refusing unsafe compatibility launcher cleanup.'
            }
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        $legacyPath = Join-Path ([IO.Path]::GetTempPath()) 'msft-runtime-bootstrap.ps1'
        if ($PSCommandPath -and [IO.Path]::GetFullPath($PSCommandPath) -ieq $legacyPath) { Remove-Item -LiteralPath $PSCommandPath -Force }
    } catch {
        Write-Host '[ FAILED ] Compatibility launcher cleanup failed.' -ForegroundColor Red
        $exitCode = 1
    }
}
exit $exitCode
