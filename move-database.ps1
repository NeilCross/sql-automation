#----------------------------------------------------------------------
# Command to relocate mirrored database files to a new storage path.
#----------------------------------------------------------------------
Param(
    $Server=([System.Net.Dns]::GetHostByName(($env:computerName)) | Select -ExpandProperty HostName),
    [Parameter(Mandatory=$true)]
    $DatabaseName,
    [Parameter(Mandatory=$true)]
    $DatabasePath,
    [Parameter(Mandatory=$true)]
    $LogPath
)
$ErrorActionPreference="stop"

$databaseName = $DatabaseName

$newDatabasePath = $DatabasePath
$newLogPath = $LogPath

$ErrorActionPreference = "stop"

[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null

#----------------------------------------------------------------------
# Verify Environment
#----------------------------------------------------------------------

$files = Invoke-Sqlcmd -ServerInstance $Server -Query "SELECT [name],[physical_name], [type_desc] FROM sys.master_files WHERE database_id = DB_ID('${databaseName}');" -Database "master"

$dataName = ($files |  Where type_desc -eq "ROWS").name
$dataPath = ($files |  Where type_desc -eq "ROWS").physical_name
$dataFileName = (GI $dataPath).Name
$dataDirectory = (GI $dataPath).DirectoryName

$logName = ($files |  Where type_desc -eq "LOG").name
$logPath = ($files |  Where type_desc -eq "LOG").physical_name
$logFileName = (GI $logPath).Name
$logDirectory = (GI $logPath).DirectoryName

if (-not (GI $dataPath))
{
    "Files not found"
    exit 
}

if ("${newDatabasePath}\${dataFileName}" -eq $dataPath -and "${newLogPath}\${logFileName}" -eq $logPath)
{
    "Files exist in destination already"
    exit 
}

#----------------------------------------------------------------------
# Failover all Principal DBs over to other server
#----------------------------------------------------------------------
$dbPrincipals = Invoke-Sqlcmd -ServerInstance $Server -Query "SELECT [A].[name] FROM sys.databases A INNER JOIN sys.database_mirroring B ON A.database_id = B.database_id WHERE B.mirroring_role = 1;" -Database "master"

if ($dbPrincipals.Length -gt 0)
{
    "Failing over databases"
    $dbPrincipals | out-string
    $failoverQuery = ($dbPrincipals | ForEach-Object {"ALTER DATABASE [" + $_.name + "] SET PARTNER FAILOVER "}) -join "`n"
    Invoke-Sqlcmd -ServerInstance $Server -Query $failoverQuery -Database "master"    
}

#----------------------------------------------------------------------
# Update paths and copy files
#----------------------------------------------------------------------

Invoke-Sqlcmd -ServerInstance $Server -Query "ALTER DATABASE ${databaseName} MODIFY FILE ( NAME = '${dataName}', FILENAME = '${newDatabasePath}\${dataFileName}');" -Database "master"
Invoke-Sqlcmd -ServerInstance $Server -Query "ALTER DATABASE ${databaseName} MODIFY FILE ( NAME = '${logName}', FILENAME = '${newLogPath}\${logFileName}');" -Database "master"

$dependantServices = (Get-Service mssqlserver).DependentServices | where status -eq running 
$dependantServices | Stop-Service
Stop-Service mssqlserver

ROBOCOPY "${dataDirectory}" "${newDatabasePath}" ${dataFileName} /copyall /mov
ROBOCOPY "${logDirectory}" "${newLogPath}" ${logFileName} /copyall /mov

Start-Service mssqlserver
$dependantServices | Start-Service