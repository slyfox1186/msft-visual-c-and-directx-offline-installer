@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # This is an interactive console installer. Write-Host is intentional so
        # status categories, progress, and summaries render consistently.
        'PSAvoidUsingWriteHost'
    )
    Rules        = @{
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
            )
        }
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
        PSUseCompatibleTypes = @{
            Enable         = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
            )
        }
    }
}
