@{
    Severity     = @('Error', 'Warning', 'Information')
    # install.ps1 is an interactive installer that talks to the person
    # running it, so Write-Host is the right tool there.
    ExcludeRules = @('PSAvoidUsingWriteHost')
}
