#Requires -Version 5.1
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module "$root/src/RuntimeInstaller.psm1" -Force
$executable = (Get-Process -Id $PID).Path
$workspace = New-InstallerWorkspace
$script:checks = 0
function Assert-True([bool]$Condition, [string]$Message) {
    $script:checks++
    if (-not $Condition) { throw $Message }
}
try {
    foreach ($scriptName in @('Start.ps1', 'Bootstrap.ps1', 'Install.ps1')) {
        foreach ($help in @('-Help', '--help')) {
            $text = & $executable -NoProfile -File "$root/$scriptName" $help | Out-String
            Assert-True ($LASTEXITCODE -eq 0 -and $text -match 'Components' -and $text -match 'ReportPath') "$scriptName $help failed."
        }
    }
    $source = [IO.File]::ReadAllText("$root/Start.ps1")
    # Force the safe platform rejection on every OS: this tests real stdin parsing
    # without allowing a Windows test runner to start the interactive installer.
    $streamed = $source.Replace('[Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT', '$true')
    $text = $streamed -split '\r?\n' | & $executable -NoProfile -Command - | Out-String
    Assert-True ($LASTEXITCODE -eq 1 -and $text -match 'supports Windows only') 'Legacy stdin launcher silently skipped execution.'

    $fixture = Join-Path $workspace 'argument fixture.ps1'
    $env:MSRI_TEST_ARGUMENT_FILE = Join-Path $workspace 'arguments.json'
    [IO.File]::WriteAllText($fixture, @'
param($Components, $DotNetChannels, $VisualCppVersions, $ReportPath, [switch]$KeepDownloads)
$PSBoundParameters | ConvertTo-Json | Set-Content -LiteralPath $env:MSRI_TEST_ARGUMENT_FILE
exit 2
'@)
    $options = @{ Components = @('DotNet', 'VisualCpp'); DotNetChannels = '8.0,10.0'; VisualCppVersions = 'v14'; ReportPath = 'C:\space and $dollar;literal\'; KeepDownloads = $true }
    $arguments = Get-InstallerChildArgument $fixture $options
    $process = Start-Process $executable -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    Assert-True ($process.ExitCode -eq 2) 'Child exit code lost.'
    $received = Get-Content $env:MSRI_TEST_ARGUMENT_FILE -Raw | ConvertFrom-Json
    Assert-True ($received.Components -ceq 'DotNet,VisualCpp') 'Component list changed during native forwarding.'
    Assert-True ($received.ReportPath -ceq $options.ReportPath) 'Quoted path changed during native forwarding.'
    Assert-True $received.KeepDownloads.IsPresent 'Switch lost during native forwarding.'

    # Extract the actual URI and path guards, without executing the launcher.
    $tree = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    foreach ($name in @('Test-AllowedGitHubUri', 'Test-SafeLauncherWorkspace')) {
        $function = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $path = '/owner/repo/commit/Install.ps1'
    Assert-True (Test-AllowedGitHubUri "https://raw.githubusercontent.com$path" 'raw.githubusercontent.com' $path) 'Valid source rejected.'
    foreach ($uri in @("http://raw.githubusercontent.com$path", "https://raw.githubusercontent.com${path}?token=x",
        "https://raw.githubusercontent.com$path#fragment", "https://user:pass@raw.githubusercontent.com$path",
        "https://raw.githubusercontent.com:444$path", "https://raw.githubusercontent.com.evil.invalid$path",
        'https://raw.githubusercontent.com/wrong/revision/Install.ps1')) {
        Assert-True (-not (Test-AllowedGitHubUri $uri 'raw.githubusercontent.com' $path)) 'Unsafe source accepted.'
    }
    Assert-True (-not (Test-SafeLauncherWorkspace ([IO.Path]::GetTempPath()))) 'Temp root accepted for recursive deletion.'
    $launcherPath = Join-Path ([IO.Path]::GetTempPath()) ('msft-runtime-launcher-' + [guid]::NewGuid().ToString('N'))
    Assert-True (Test-SafeLauncherWorkspace $launcherPath) 'Valid launcher workspace rejected.'

    $compatibility = Join-Path $workspace 'msft-runtime-bootstrap.ps1'
    Copy-Item "$root/Bootstrap.ps1" $compatibility
    $harness = Join-Path $workspace 'cleanup-fixture.ps1'
    [IO.File]::WriteAllText($harness, @'
$env:TEMP = $env:TMP = $env:TMPDIR = $PSScriptRoot
function Remove-Item { throw 'Synthetic cleanup failure' }
& (Join-Path $PSScriptRoot 'msft-runtime-bootstrap.ps1') -Help
exit $LASTEXITCODE
'@)
    $text = & $executable -NoProfile -File $harness | Out-String
    Assert-True ($LASTEXITCODE -eq 1 -and $text -match 'cleanup failed') 'Compatibility help ignored cleanup failure.'
} finally {
    Remove-Item Env:MSRI_TEST_ARGUMENT_FILE -ErrorAction SilentlyContinue
    Remove-InstallerWorkspace $workspace
}
Write-Output "Launcher checks passed: $script:checks"
