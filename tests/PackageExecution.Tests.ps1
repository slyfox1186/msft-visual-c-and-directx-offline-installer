#Requires -Version 5.1
param([string]$ModulePath = "$PSScriptRoot/../src/RuntimeInstaller.psm1")
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
$module = Get-Module RuntimeInstaller
$workspace = New-InstallerWorkspace
$script:checks = 0
function Assert-True([bool]$Condition, [string]$Message) {
    $script:checks++
    if (-not $Condition) { throw $Message }
}
function Assert-Rejected([scriptblock]$Action) {
    $script:checks++
    try { & $Action } catch { return }
    throw 'Expected rejection.'
}
try {
    # Replace only OS/network boundaries. The production download, verification,
    # cleanup and installation functions execute unchanged.
    $curlPath = Join-Path $workspace 'curl-fixture.ps1'
    [IO.File]::WriteAllText($curlPath, @'
$destination = $args[[array]::IndexOf($args, '--output') + 1]
[IO.File]::WriteAllText($destination, 'test package bytes')
if ($env:MSRI_TEST_CURL_FAILURE -eq 'yes') { exit 22 }
$env:MSRI_TEST_EFFECTIVE_URI
exit 0
'@)
    & $module {
        param($CurlPath)
        $script:TestCurlPath = $CurlPath
        function script:Get-CurlExecutable { $script:TestCurlPath }
        function script:Get-AuthenticodeSignature {
            [CmdletBinding()]
            param([string]$LiteralPath)
            if (-not (Test-Path -LiteralPath $LiteralPath)) { throw 'Missing signature target.' }
            [pscustomobject]@{ Status = $script:TestSignatureStatus; SignerCertificate = [pscustomobject]@{ Subject = $script:TestSigner } }
        }
        function script:Get-VisualCppFileVersion { [version]$script:TestFileVersion }
        function script:Start-Process {
            [CmdletBinding()]
            param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
            if (-not $Wait -or -not $PassThru) { throw 'Package execution must wait and collect its exit code.' }
            $script:TestExecutions += [pscustomobject]@{ FilePath = $FilePath; Arguments = $ArgumentList }
            if ($ArgumentList -contains '/Q') {
                $directory = ($ArgumentList | Where-Object { $_ -like '/T:*' }).Substring(4).TrimEnd('"')
                [IO.File]::WriteAllText((Join-Path $directory 'DXSETUP.exe'), 'extracted fixture')
                return [pscustomobject]@{ ExitCode = 0 }
            }
            [pscustomobject]@{ ExitCode = $script:TestExitCode }
        }
        $script:TestSignatureStatus = 'Valid'
        $script:TestSigner = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US'
        $script:TestFileVersion = '14.1.0.0'
        $script:TestExecutions = @()
        $script:TestExitCode = 0
    } $curlPath
    $env:MSRI_TEST_EFFECTIVE_URI = 'https://download.microsoft.com/fixture.exe'
    $file = Join-Path $workspace 'fixture.exe'
    $env:MSRI_TEST_CURL_FAILURE = 'yes'
    Assert-Rejected { Invoke-CurlDownload $env:MSRI_TEST_EFFECTIVE_URI $file -ShowProgress $false }
    Assert-True (-not (Test-Path $file)) 'Failed download was retained.'
    $env:MSRI_TEST_CURL_FAILURE = 'no'
    $env:MSRI_TEST_EFFECTIVE_URI = 'https://evil.invalid/fixture.exe'
    Assert-Rejected { Invoke-CurlDownload 'https://download.microsoft.com/fixture.exe' $file -ShowProgress $false }
    Assert-True (-not (Test-Path $file)) 'Unapproved redirect download was retained.'
    $env:MSRI_TEST_EFFECTIVE_URI = 'https://download.microsoft.com/fixture.exe'
    $cfg = Import-PowerShellDataFile "$PSScriptRoot/../config/packages.psd1"
    $package = @(Get-VisualCppPackage $cfg x86 v14)[0]
    $package | Add-Member Uri $env:MSRI_TEST_EFFECTIVE_URI
    $file = Join-Path $workspace $package.FileName
    $completed = 0
    $restart = $false
    $invoke = {
        if (Get-Command Invoke-RuntimeInstallation -ErrorAction SilentlyContinue) {
            Invoke-RuntimeInstallation @($package) $workspace VisualCpp ([ref]$completed) ([ref]$restart)
        }
        else {
            Invoke-VisualCppInstallation @($package) $workspace ([ref]$completed) ([ref]$restart)
        }
    }
    Assert-Rejected $invoke
    Assert-True (-not (Test-Path $file)) 'Version-floor rejection retained an untrusted package.'
    Assert-True ((& $module { $script:TestExecutions.Count }) -eq 0) 'Rejected package executed.'
    & $module { param($Version) $script:TestFileVersion = $Version; $script:TestSigner = 'O=Attacker' } $package.MinimumVersion
    Assert-Rejected $invoke
    Assert-True (-not (Test-Path $file)) 'Wrong signer was retained.'
    & $module { $script:TestSigner = 'O=Microsoft Corporation'; $script:TestSignatureStatus = 'HashMismatch' }
    Assert-Rejected $invoke
    Assert-True (-not (Test-Path $file)) 'Invalid signature was retained.'
    & $module { $script:TestSignatureStatus = 'Valid'; $script:TestExitCode = 3010 }
    Invoke-RuntimeInstallation @($package) $workspace VisualCpp ([ref]$completed) ([ref]$restart)
    Assert-True ($completed -eq 1 -and $restart) 'Restart result/count lost.'
    Assert-True ((& $module { $script:TestExecutions.Count }) -eq 1) 'Verified package did not execute exactly once.'
    $sdk = [pscustomobject]@{ Name = 'SDK fixture'; FileName = 'sdk.exe'; Uri = $env:MSRI_TEST_EFFECTIVE_URI; Sha512 = '0' * 128; Arguments = @('/passive', '/norestart') }
    Assert-Rejected { Invoke-RuntimeInstallation @($sdk) $workspace DotNet ([ref]$completed) ([ref]$restart) }
    Assert-True (-not (Test-Path (Join-Path $workspace $sdk.FileName))) 'Hash mismatch was retained.'
    $directX = Get-DirectXPackage $cfg
    $directX | Add-Member Uri $env:MSRI_TEST_EFFECTIVE_URI
    $directX.Sha256 = (Get-FileHash $file -Algorithm SHA256).Hash
    Invoke-RuntimeInstallation @($directX) $workspace DirectX ([ref]$completed) ([ref]$restart)
    $executions = @(& $module { $script:TestExecutions })
    Assert-True ($executions.Count -eq 3 -and $completed -eq 2) 'DirectX extraction/setup count incorrect.'
    Assert-True ($executions[-1].Arguments[0] -eq '/silent') 'DirectX switch changed.'
    Assert-True ($executions[0].Arguments -contains '/norestart') 'Visual C++ restart suppression lost.'
} finally {
    Remove-Item Env:MSRI_TEST_CURL_FAILURE, Env:MSRI_TEST_EFFECTIVE_URI -ErrorAction SilentlyContinue
    Remove-InstallerWorkspace $workspace
    Import-Module $ModulePath -Force
}
Write-Output "Package execution checks passed: $script:checks (OS/network boundaries simulated)"
