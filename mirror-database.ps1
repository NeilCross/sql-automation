# Modified with fixes and modifications from http://www.zerrouki.com/mirror-database/
Param(
    $PrincipalServer=([System.Net.Dns]::GetHostByName(($env:computerName)) | Select -ExpandProperty HostName),
    [Parameter(Mandatory=$true, HelpMessage="You must provide a server address to host the mirror; ie: 192.168.1.2 or 192.168.1.2\NamedInstance.")]
    $MirrorServer,
    $WitnessServer,
    $PrincipalServerPort="1433",
    $MirrorServerPort="1433",
    $WitnessServerPort="1433",
    [Parameter(Mandatory=$true)]
    [ValidateScript({
        if ($_ -match "^(master|msdb|temp|model)$") {Write-Host "Only user databases can be mirrored. You cannot mirror the master, msdb, tempdb or model databases.`n" -ForegroundColor Red; Break} else {$True}
    })]
    $DbName,
    [Parameter(Mandatory=$true, HelpMessage="You must provide the Windows Service Account for MS SQL Server; Must be a Domain Account.")]
    $SQLDomainAccount,
    $BackupPath
)
$ErrorActionPreference="stop"
 
Function Ask-YesOrNo ([string]$title="Confirmation needed",[string]$message)
{
    $choiceYes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Answer Yes."
    $choiceNo = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Answer No."
    $options = [System.Management.Automation.Host.ChoiceDescription[]]($choiceYes, $choiceNo)
    $result = $host.ui.PromptForChoice($title, $message, $options, 1)
    switch ($result)
    {
    0
        {Return $true}
    1
        {Return $false}
    }
}
 
function Test-Port ([string]$Server, [int]$Port)
{
    Try
    {
        $c=New-Object System.Net.Sockets.TcpClient($Server, $Port)
        $c.Close()
        return $true
    }
    Catch
    {
        [System.Exception]
        return $false
    }
}

function Test-MirroringPrerequisites
{
    [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMO") | Out-Null
    [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMOExtended") | Out-Null
    $PrincipalServerConnect=New-Object Microsoft.SqlServer.Management.Smo.Server $PrincipalServer
    $MirrorServerConnect=New-Object Microsoft.SqlServer.Management.Smo.Server $MirrorServer
 
    Write-Host "`nPrerequisites checks" -ForegroundColor Yellow    

    # Check the server version matches
    $PrincipalServerVersion= [string]::Format("{0}.{1}.{2}.{3} Edition", $PrincipalServerConnect.Version.Major,$PrincipalServerConnect.Version.Minor, $PrincipalServerConnect.Version.Build, $PrincipalServerConnect.EngineEdition)
    $MirrorServerVersion=[string]::Format("{0}.{1}.{2}.{3} Edition", $MirrorServerConnect.Version.Major,$MirrorServerConnect.Version.Minor, $MirrorServerConnect.Version.Build, $MirrorServerConnect.EngineEdition)

    if ($PrincipalServerVersion -eq $MirrorServerVersion) {
        Write-Host " √ both principal server ($PrincipalServerVersion) and mirror server ($MirrorServerVersion) are running on the same version and edition of Microsoft SQL Server." -ForegroundColor DarkGreen
    } else {
        Write-Host "Principal server ($PrincipalServerVersion) and mirror server ($MirrorServerVersion) are NOT running the same version/edition of Microsoft SQL Server. Exiting now." -ForegroundColor Red; 
        return $false;
    }

    if ($WitnessServer) {
        $WitnessServerConnect=New-Object Microsoft.SqlServer.Management.Smo.Server $WitnessServer
        $PrincipalServerVersionShort=[string]::Format("{0}.{1}",$PrincipalServerConnect.Version.Major,$PrincipalServerConnect.Version.Minor)
        $WitnessServerVersionShort=[string]::Format("{0}.{1}",$WitnessServerConnect.Version.Major,$WitnessServerConnect.Version.Minor)
        if ($PrincipalServerVersionShort -eq $WitnessServerVersionShort) {
            Write-Host " √ both principal server ($PrincipalServerVersionShort) and witness server ($WitnessServerVersionShort) are running on the same version of Microsoft SQL Server." -ForegroundColor DarkGreen
        } else {
            Write-Host "Principal server ($PrincipalServerVersionShort) and witness server ($WitnessServerVersionShort) are NOT running the same version of Microsoft SQL Server. Exiting now." -ForegroundColor Red; 
            return $false;
        }
    }

    # Test that server collation Matches
    $PrincipalServerCollation=$PrincipalServerConnect.Collation
    $MirrorServerCollation=$MirrorServerConnect.Collation
    if ($PrincipalServerCollation -eq $MirrorServerCollation) {
        Write-Host " √ principal server is configured to use the same collation as mirror server ($PrincipalServerCollation)." -ForegroundColor DarkGreen
    } else {
        if (!(Ask-YesOrNo -Message "* Principal server is configured to use a different collation ($PrincipalServerCollation) as mirror server ($MirrorServerCollation).Differences can cause a problem during mirroring setup. Are you sure you want to continue?")) {
            Write-Host "You have chosen to end this script execution. That's a wise decision!"; 
            return $false;
        }
    }
 
    #Test that the Source DB uses the Full Recovery model
    $DbInfo=$PrincipalServerConnect.Databases | Where-Object {$_.Name -eq $DbName} | Select-Object RecoveryModel
    if ($DbInfo.RecoveryModel -eq "Full") {Write-Host " √ the recovery model for database `"$DbName`" is Full." -ForegroundColor DarkGreen} else {Write-Host "The principal database must be in the FULL recovery mode. Exiting now." -ForegroundColor Red; Write-Host "Here is the SQL query to run to enable the FULL recovery mode on your database:`nALTER DATABASE $DbName`nSET RECOVERY Full"; Break}
 
    $ExistingMirror=$PrincipalServerConnect.Databases | Where-Object { $_.IsMirroringEnabled -and ($_.Name -eq "$DbName") }
    $ExistingMirrorPartner=$ExistingMirror | % {$_.MirroringPartner}
    $ExistingMirrorPartnerInstance=$ExistingMirror | % {$_.MirroringPartnerInstance}
    $ExistingMirrorWitness=$ExistingMirror | % {$_.MirroringWitness}

    # Test that the database is not already mirrored.
    if (!$ExistingMirrorWitness) {$ExistingMirrorWitness="N/A"}
    if (!$ExistingMirror) {
        Write-Host " √ $DbName database is not already mirrored." -ForegroundColor DarkGreen
    }
    else {
        Write-Host "$DbName database is already mirrored with $ExistingMirrorPartnerInstance (EndPoint: $ExistingMirrorPartner - Witness: $ExistingMirrorWitness). Exiting now." -ForegroundColor Red;
        return $false;
    }
    return $true;
}

if(!(Test-Port $PrincipalServer $PrincipalServerPort)) {Write-Host "`nUnable to connect to Principal server (${PrincipalServer}:${PrincipalServerPort}). Exiting now." -ForegroundColor Red; Break}
if(!(Test-Port $MirrorServer $MirrorServerPort)) {Write-Host "`nUnable to connect to Mirror server (${MirrorServer}:${MirrorServerPort}). Exiting now." -ForegroundColor Red; Break}
if ($WitnessServer) { if(!(Test-Port $WitnessServer $WitnessServerPort)) {Write-Host "`nUnable to connect to Witness server (${WitnessServer}:${WitnessServerPort}). Exiting now." -ForegroundColor Red; Break} } else { $WitnessServer="N/A" }

Write-Host "`nAutomatic Database Mirroring tool - Parameters" -ForegroundColor Yellow
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " Principal Server (-PrincipalServer)            :`t" -nonewline; Write-Host "$PrincipalServer" -ForegroundColor DarkGreen -nonewline; Write-Host " (TCP $PrincipalServerPort)"
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " Mirror Server (-MirrorServer)                  :`t" -nonewline; Write-Host "$MirrorServer" -ForegroundColor DarkGreen -nonewline; Write-Host " (TCP $MirrorServerPort)"
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " Witness Server (-WitnessServer)                :`t" -nonewline; Write-Host "$WitnessServer" -ForegroundColor DarkGreen -nonewline; if ($WitnessServer -notmatch "N/A") {Write-Host " (TCP $WitnessServerPort)"} else {Write-Host ""}
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " Database Name (-DbName)                        :`t" -nonewline; Write-Host "$DbName" -ForegroundColor DarkGreen
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " SQL Service Domain Account (-SQLDomainAccount) :`t" -nonewline; Write-Host "$SQLDomainAccount" -ForegroundColor DarkGreen
if (!(Ask-YesOrNo -Message "The parameters above will be used. Are you sure you want to continue?")) {Write-Host "You have chosen to end this script execution. That's a wise decision!"; Break}
 

if (!(Test-MirroringPrerequisites))
{
    break;
}

Write-Host "Prerequisites checks completed successfully.`n" -ForegroundColor Yellow

#.\retrieve-database.ps1 -SourceServer $PrincipalServer -DestinationServer ${MirrorServer} -SourceDbName ${DbName} 

if ($BackupPath -eq $null)
{
    $BackupPath = "\\${MirrorServer}\e$\backup\"
}

$DbBackUpQuery=@"
USE master
GO
BACKUP DATABASE $DbName TO DISK = '$BackupPath\${DbName}-temp_for_mirror.bak'
WITH INIT
GO
BACKUP LOG $DbName TO DISK = '$BackupPath\${DbName}-temp_for_mirror.bak'
GO
"@

$DbRestoreQuery=@"
USE master
GO
RESTORE DATABASE $DbName FROM DISK = '$BackupPath\${DbName}-temp_for_mirror.bak'
WITH FILE = 1, NORECOVERY, REPLACE
GO
RESTORE LOG $DbName FROM DISK = '$BackupPath\${DbName}-temp_for_mirror.bak'
WITH FILE = 2, NORECOVERY
GO
"@
 
#Add-PSSnapin SqlServerCmdletSnapin100

Write-Host "Backup of the $DbName database started. Please wait..."
Invoke-Sqlcmd -ServerInstance $PrincipalServer -Query $DbBackUpQuery -QueryTimeout 0
Write-Host "Backup of the $DbName database completed successfully." -ForegroundColor Yellow

Write-Host "Restore of the $DbName database started on $MirrorServer. Please wait..."
Invoke-Sqlcmd -ServerInstance $MirrorServer -Query $DbRestoreQuery -QueryTimeout 0
Write-Host "Restore of the $DbName database on $MirrorServer completed successfully." -ForegroundColor Yellow

Remove-Item $BackupPath\${DbName}-temp_for_mirror.bak -ErrorAction Continue

$DbPartnerEndpointQuery=@"
USE master
GO
IF NOT EXISTS (SELECT * FROM sys.tcp_endpoints WHERE type_desc = 'DATABASE_MIRRORING')
CREATE ENDPOINT Mirroring
    STATE = STARTED
    AS TCP ( LISTENER_PORT = 5022)
    FOR DATABASE_MIRRORING (ROLE=PARTNER);
GO
"@
$DbWitnessEndpointQuery=@"
USE master
GO
IF NOT EXISTS (SELECT * FROM sys.tcp_endpoints WHERE type_desc = 'DATABASE_MIRRORING')
CREATE ENDPOINT Mirroring
    STATE = STARTED
    AS TCP ( LISTENER_PORT = 5022)
    FOR DATABASE_MIRRORING (ROLE=WITNESS)
GO
"@ 

Write-Host "Creation of the Endpoints for Mirroring. Please wait..."

Invoke-Sqlcmd -ServerInstance $PrincipalServer -Query $DbPartnerEndpointQuery 
Write-Host "Creation of the Endpoint 'Mirroring' on $PrincipalServer completed successfully." -ForegroundColor Yellow

Invoke-Sqlcmd -ServerInstance $MirrorServer -Query $DbPartnerEndpointQuery 
Write-Host "Creation of the Endpoint 'Mirroring' on $MirrorServer completed successfully." -ForegroundColor Yellow

if ($WitnessServer -notmatch "N/A") {
    Invoke-Sqlcmd -ServerInstance $WitnessServer -Query $DbWitnessEndpointQuery 
    Write-Host "Creation of the Endpoint 'Mirroring' on $WitnessServer completed successfully." -ForegroundColor Yellow
}

$DbGrantEndpoint=@"
IF NOT EXISTS (SELECT name FROM master.sys.server_principals WHERE name = '${SQLDomainAccount}')
    CREATE LOGIN [${SQLDomainAccount}] FROM WINDOWS
GO
IF NOT EXISTS (SELECT name FROM sys.database_principals WHERE name = '${SQLDomainAccount}')
    CREATE USER [${SQLDomainAccount}] FROM LOGIN [${SQLDomainAccount}]
GO
GRANT CONNECT ON ENDPOINT::Mirroring TO [${SQLDomainAccount}]
GO
"@

Write-Host "Granting access on the Endpoints for $SQLDomainAccount account. Please wait..."

Invoke-Sqlcmd -ServerInstance $PrincipalServer -Query $DbGrantEndpoint
Invoke-Sqlcmd -ServerInstance $MirrorServer -Query $DbGrantEndpoint 

if ($WitnessServer -notmatch "N/A") {
    Invoke-Sqlcmd -ServerInstance $WitnessServer -Query $DbGrantEndpoint 
}
 
$DbPrincipalPartnerQuery=@"
USE master
GO
ALTER DATABASE $DbName SET PARTNER = 'TCP://${MirrorServer}:5022'
GO
"@
$DbMirrorPartnerQuery=@"
USE master
GO
ALTER DATABASE $DbName SET PARTNER = 'TCP://${PrincipalServer}:5022'
GO
"@
$DbPrincipalWitnessQuery=@"
USE master
GO
ALTER DATABASE $DbName SET WITNESS = 'TCP://${WitnessServer}:5022'
GO
"@

Write-Host "Creation of partnership for Mirroring. Please wait..."

Invoke-Sqlcmd -ServerInstance $MirrorServer -Query $DbMirrorPartnerQuery 
Write-Host "Partner for $MirrorServer created successfully." -ForegroundColor Yellow

Invoke-Sqlcmd -ServerInstance $PrincipalServer -Query $DbPrincipalPartnerQuery 
Write-Host "Partner for $PrincipalServer created successfully." -ForegroundColor Yellow

if ($WitnessServer -notmatch "N/A") {
    Invoke-Sqlcmd -ServerInstance $PrincipalServer -Query $DbPrincipalWitnessQuery 
    Write-Host "Partnership for $WitnessServer (Witness) created successfully." -ForegroundColor Yellow
}
