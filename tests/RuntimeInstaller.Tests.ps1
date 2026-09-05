#Requires -Version 5.1
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/RuntimeInstaller.psm1" -Force
$configuration = Import-PowerShellDataFile "$PSScriptRoot/../config/packages.psd1"
$script:checks = 0

function Assert-Equal($Actual, $Expected) {
    $script:checks++
    if ([string]$Actual -cne [string]$Expected) { throw "Expected '$Expected', got '$Actual'." }
}
function Assert-Rejected([scriptblock]$Action, [string]$Pattern = '.') {
    $script:checks++
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw 'Expected rejection, but the operation succeeded.'
}

Assert-Equal ((Resolve-ComponentSelection All DirectX) -join ',') 'DotNet,VisualCpp'
Assert-Equal ((Resolve-ComponentSelection 'visualcpp,dotnet') -join ',') 'DotNet,VisualCpp'
foreach ($value in @('', 'All,DotNet', 'DotNet,dotnet', 'DotNet,', 'Unknown')) {
    Assert-Rejected { Resolve-ComponentSelection $value }
}
Assert-Rejected { Resolve-ComponentSelection DotNet DotNet }
foreach ($component in @('DotNet', 'VisualCpp', 'DirectX', 'All')) {
    $options = Resolve-InstallerOptionSet -Configuration $configuration -Components $component
    $roundTrip = Resolve-InstallerOptionSet -Configuration $configuration @options
    Assert-Equal ($roundTrip.Components -join ',') ($options.Components -join ',')
}
Assert-Equal (ConvertTo-InstallerArgument 'C:\space here\') '"C:\space here\\"'
Assert-Equal (ConvertTo-InstallerArgument 'C:\space here\file.txt') '"C:\space here\file.txt"'
Assert-Rejected { ConvertTo-InstallerArgument 'bad"argument' } 'quotation'
Assert-Rejected { ConvertTo-InstallerArgument "bad`nargument" } 'control'
Assert-Rejected { Get-InstallerChildArgument 'Install.ps1' @{ 'BadName' = 'value' } } 'Unsupported'
Assert-Equal ((Resolve-DotNetChannelSelection '10,8') -join ',') '8.0,10.0'
Assert-Equal ((Resolve-DotNetChannelSelection '10.0,8.0') -join ',') '8.0,10.0'
foreach ($value in @('8.0,8.0', 'All,8.0', '8.0-preview', '../8.0', '8.0,')) {
    Assert-Rejected { Resolve-DotNetChannelSelection $value }
}
foreach ($architecture in @('x86', 'x64', 'arm64')) {
    $packages = @(Get-VisualCppPackage $configuration $architecture)
    $expectedCount = if ($architecture -eq 'x86') { 6 } else { 12 }
    Assert-Equal $packages.Count $expectedCount
    Assert-Equal @(Get-VisualCppPackage $configuration $architecture '2013,v14').Count ($expectedCount / 3)
    Assert-Equal (Get-TargetArchitecture -OperatingSystemArchitecture $architecture) $architecture
}
Assert-Rejected { Get-TargetArchitecture -OperatingSystemArchitecture Arm }
Assert-Rejected { Get-VisualCppPackage @{ VisualCpp = @($configuration.VisualCpp[0], $configuration.VisualCpp[0]) } x64 } 'Duplicate'
$badConfiguration = Import-PowerShellDataFile "$PSScriptRoot/../config/packages.psd1"
$badConfiguration.VisualCpp[0].Sha256 = 'invalid'
Assert-Rejected { Get-VisualCppPackage $badConfiguration x64 } 'SHA-256'

foreach ($uri in @('http://download.microsoft.com/a.exe', 'https://download.microsoft.com.evil.invalid/a.exe',
    'https://user:secret@download.microsoft.com/a.exe', 'https://download.microsoft.com:444/a.exe', '/a.exe')) {
    Assert-Equal (Test-AllowedMicrosoftUri $uri) $false
}
Assert-Equal (Test-AllowedMicrosoftUri 'https://download.microsoft.com/a.exe') $true
Assert-Equal (Test-AllowedMicrosoftUri 'https://learn.microsoft.com/a.exe') $false
Assert-Equal (Test-AllowedMicrosoftDiscoveryUri 'https://learn.microsoft.com/page') $true
Assert-Equal (Test-AllowedMicrosoftDiscoveryUri 'https://download.microsoft.com/a.exe') $false
try { Assert-MicrosoftUri 'https:/user:DEMO_PASSWORD@example.invalid/a?token=DEMO_TOKEN' } catch {
    Assert-Equal ($_.Exception.Message -match 'DEMO_PASSWORD|DEMO_TOKEN') $false
}
foreach ($name in @('../payload.exe', 'C:\payload.exe', 'bad.exe:stream', 'a.exe/other', 'a.exe?x')) {
    Assert-Rejected { Assert-InstallerFileName $name }
}
foreach ($kind in @('DotNet', 'VisualCpp', 'DirectX', 'Extractor')) {
    Assert-Equal (Get-InstallerResult 0 $kind) 'Success'
    Assert-Equal (Get-InstallerResult 1641 $kind) 'Failure'
    Assert-Equal (Get-InstallerResult 1603 $kind) 'Failure'
    $expectedRestart = if ($kind -eq 'Extractor') { 'Failure' } else { 'RestartRequired' }
    Assert-Equal (Get-InstallerResult 3010 $kind) $expectedRestart
    $expectedConflict = if ($kind -eq 'VisualCpp') { 'AlreadyInstalled' } else { 'Failure' }
    Assert-Equal (Get-InstallerResult 1638 $kind) $expectedConflict
}
Assert-Equal (Test-MicrosoftSignerSubject 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US') $true
Assert-Equal (Test-MicrosoftSignerSubject 'CN=Microsoft Corporation, O=Attacker, C=US') $false
Assert-Equal (Test-MicrosoftSignerSubject 'O=Microsoft Corporation Attacker') $false
$rolling = @(Get-VisualCppPackage $configuration x86 v14)[0]
Assert-Equal (Assert-VisualCppVersionPolicy $rolling ([version]$rolling.MinimumVersion)) $true
foreach ($version in @('14.0.99999.0', '14.1.0.0', '15.0.0.0')) {
    Assert-Rejected { Assert-VisualCppVersionPolicy $rolling ([version]$version) }
}

$sdkFile = [pscustomobject]@{ rid = 'win-x64'; url = 'https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.100/dotnet-sdk-8.0.100-win-x64.exe'; hash = 'a' * 128 }
$sdk = [pscustomobject]@{ version = '8.0.100'; files = @($sdkFile) }
$metadata = [pscustomobject]@{ 'latest-sdk' = '8.0.100'; 'channel-version' = '8.0'; releases = @([pscustomobject]@{ sdks = @($sdk) }) }
Assert-Equal (Resolve-DotNetSdkPackage $metadata x64).Version '8.0.100'
$metadata.'channel-version' = '9.0'
Assert-Rejected { Resolve-DotNetSdkPackage $metadata x64 } 'channel'
$metadata.'channel-version' = '8.0'
Assert-Rejected { Resolve-DotNetSdkPackage $metadata x86 } 'exactly one'
$sdk.files = @($sdkFile, $sdkFile)
Assert-Rejected { Resolve-DotNetSdkPackage $metadata x64 } 'exactly one'
$sdk.files = @($sdkFile)
$sdkFile.hash = 'a' * 127
Assert-Rejected { Resolve-DotNetSdkPackage $metadata x64 } 'SHA-512'
$sdkFile.hash = 'a' * 128
$metadata.releases[0].sdks = @($sdk, $sdk)
Assert-Rejected { Resolve-DotNetSdkPackage $metadata x64 } 'exactly one'
Assert-Rejected { Select-DotNetSdkPackage @([pscustomobject]@{ Channel = '8.0' }) '99.0' } 'not currently supported'

$legacy = @(Get-VisualCppPackage $configuration x86 2008)[0]
$document = "### Visual Studio 2008 (VC++ 9.0) SP1`n| x86 | 9.0.30729.6161 | [Download](https://download.microsoft.com/download/a/vcredist_x86.exe) |`n"
Assert-Equal (Find-MicrosoftPayloadUri $document $legacy) 'https://download.microsoft.com/download/a/vcredist_x86.exe'
Assert-Rejected { Find-MicrosoftPayloadUri ($document + $document) $legacy } 'exactly one'
Assert-Rejected { Find-MicrosoftPayloadUri ($document.Replace('download.microsoft.com', 'evil.invalid')) $legacy } 'Rejected'

$workspace = New-InstallerWorkspace
try {
    Assert-Equal (Test-SafeInstallerWorkspacePath $workspace) $true
    $link = Join-Path ([IO.Path]::GetTempPath()) ('msft-runtime-installer-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType SymbolicLink -Path $link -Target $workspace
    try {
        Assert-Rejected { Remove-InstallerWorkspace $link } 'reparse-point'
        Assert-Equal (Test-Path $workspace) $true
    } finally { Remove-Item -LiteralPath $link -Force }
    foreach ($path in @([IO.Path]::GetTempPath(), (Join-Path $workspace 'child'), "$workspace-extra")) {
        Assert-Equal (Test-SafeInstallerWorkspacePath $path) $false
        Assert-Rejected { Remove-InstallerWorkspace $path } 'unsafe'
    }
    $file = Join-Path $workspace 'fixture.exe'
    [IO.File]::WriteAllText($file, 'fixture bytes')
    Assert-FileSha512 $file (Get-FileHash $file -Algorithm SHA512).Hash
    Assert-FileSha256 $file (Get-FileHash $file -Algorithm SHA256).Hash
    Assert-Rejected { Assert-FileSha512 $file ('0' * 128) } 'mismatch'
    Assert-Rejected { Invoke-CurlDownload 'https://download.microsoft.com/a.exe' $file } 'overwrite'
    $module = Get-Module RuntimeInstaller
    Assert-Rejected { & $module { param($Path) Confirm-DownloadedPackage $Path { throw 'synthetic trust rejection' } } $file } 'trust rejection'
    Assert-Equal (Test-Path $file) $false
} finally { Remove-InstallerWorkspace $workspace }
Assert-Equal (Test-Path $workspace) $false
Write-Output "Runtime regression checks passed: $script:checks"
