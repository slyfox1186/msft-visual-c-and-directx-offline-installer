@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # This is an interactive console installer. Write-Host is intentional so
        # status categories, progress, and summaries render consistently.
        'PSAvoidUsingWriteHost'
    )
}
