#SQL Automation scripts

These are some basic scripts that allow automated backup/restore/mirroring functionality.


Sample invocation for clone from one server and restore to another server then enable mirroring

	$sourceServer = "sourceServer"
    $database = "DatabaseName"
    $destinationPrimary = "DestinationPrimary"
    $destinationMirror = "DestinationMirror"
    $witnessServer = "MirroringWitness"
    $mirroringAccount = "MirroringAccount"
    $backupPath = "\\destination\backup"

    .\clone-database.ps1 -SourceServer $sourceServer -SourceDatabase $database -DestinationServers $destinationPrimary -BackupPath $backupPath -ForMirroring $true
    .\mirror-database.ps1 -PrincipalServer $destinationPrimary -MirrorServer $destinationMirror -WitnessServer $witnessServer -DbName $database -SQLDomainAccount $mirroringAccount -BackupPath $backupPath

Sample invocation for move-database

    $server = "ServerAddress"
    $database = "DatabaseName"
    $databasePath = "d:\new\log\path"
    $logPath = "l:\new\log\path"

    .\move-database.ps1 -Server $server -DatabaseName $database -DatabasePath $databasePath -LogPath $logPath
