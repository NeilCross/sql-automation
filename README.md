#SQL Automation scripts

These are some basic scripts that allow automated backup/restore/mirroring functionality.


Sample invocation for clone from one server and restore to another server then enable mirroring

    $database = "DatabaseName"
    $destinationPrimary = "DestinationPrimary"
    $destinationMirror = "DestinationMirror"
    $witnessServer = "MirroringWitness"
    $mirroringAccount = "MirroringAccount"
    $backupPath = "\\destination\backup"

    .\clone-database.ps1 -SourceDatabase $database -DestinationDatabases $database -DestinationServers $destinationServer -BackupPath $backupPath -ForMirroring $true
    .\mirror-database.ps1 -PrincipalServer $destinationPrimary -MirrorServer $destinationMirror -WitnessServer $witnessServer -DbName $database -SQLDomainAccount $mirroringAccount -BackupPath $backupPath
