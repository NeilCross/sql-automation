# Modified with fixes and modifications from http://www.zerrouki.com/mirror-database/
Param(
    $SourceServer=([System.Net.Dns]::GetHostByName(($env:computerName)) | Select -ExpandProperty HostName),
    [Parameter(Mandatory=$true, HelpMessage="The database to clone." )]
    [ValidateScript({
        if ($_ -eq "") {Write-Host "Source Database is required, please specify a value for -SourceDatabase.`n" -ForegroundColor Red; Break} else {$True}
        if ($_ -match "^(master|msdb|temp|model)$") {Write-Host "Only user databases can be cloned. You cannot mirror the master, msdb, tempdb or model databases.`n" -ForegroundColor Red; Break} else {$True}
    })]
    $SourceDatabase,
    [string[]]$DestinationServers,
    [Parameter(Mandatory=$true, HelpMessage="The database to create from the clone.")]
    [ValidateScript({
        if ($_ -eq "") {Write-Host "Destination Database is required, please specify a value for -DestinationDatabase.`n" -ForegroundColor Red; Break} else {$True}
        if ($_ -match "^(master|msdb|temp|model)$") {Write-Host "Only user databases can be cloned to. You cannot mirror the master, msdb, tempdb or model databases.`n" -ForegroundColor Red; Break} else {$True}
    })]
    [string[]]$DestinationDatabases,
    $BackupPath,
    $RestoreDataPath='not specified',
    $RestoreLogPath='not specified',
    $ForMirroring = $false
)
$ErrorActionPreference="stop"
Get-Job | ForEach { Remove-Job $_.Id }

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

function Test-ClonePrerequisites
{ 
    Write-Host "`nPrerequisites checks" -ForegroundColor Yellow    

    $db = (New-Object Microsoft.SqlServer.Management.Smo.Server $SourceServer).Databases | where-Object {$_.Name -eq $SourceDatabase}

    if ($db -eq $null)
    {
        Write-Host "Cannot connect to $SourceServer/$SourceDatabase. Exiting now." -ForegroundColor Red; 
        return $false;
    }

    if ($db.Status -ne "Normal")
    {
        return $false;
    }

    foreach ($server in $DestinationServers | Get-Unique)
    {
        $db = (New-Object Microsoft.SqlServer.Management.Smo.Server $server)
        if ($db -eq $null)
        {
            Write-Host "Cannot connect to $server. Exiting now." -ForegroundColor Red; 
            return $false;
        }
    }

    return $true;
}

function Add-TrailingSlashToPath([string] $path)
{
    
    if (!($path -match "\\$"))
    {
        return "$path\";
    }
    return $path;
}

# load the powershell module
#push/pop location to prevent path change
Push-Location
Import-Module SQLPS -DisableNameChecking
Pop-Location

if ($BackupPath -eq $null)
{
    $BackupPath = (New-Object Microsoft.SqlServer.Management.Smo.Server $SourceServer).Settings.BackupDirectory;        
}
$BackupPath = Add-TrailingSlashToPath $BackupPath;

if ($DestinationServers -eq $null)
{
    $DestinationServers = $SourceServer
}

# if there's only one destination server make the destination server list as long as the destinationDatabase length
if ($DestinationDatabases.Length -eq 1)
{
    $DestinationDatabases = ([System.Linq.Enumerable]::Repeat($DestinationDatabases, $DestinationServers.Length))
}

#if there's an in-compatible number of destination servers to destination databases error out.
if ($DestinationServers.Length -ne $DestinationDatabases.Length)
{
    Write-Host "Difference in number of Destination servers and databases." -ForegroundColor Red; 
    break;
}

Write-Host "`nAutomatic Database Mirroring tool - Parameters" -ForegroundColor Yellow
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " Source Server (-SourceServer)                : " -nonewline; Write-Host $SourceServer -ForegroundColor DarkGreen
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " Source Database (-SourceDatabase)            : " -nonewline; Write-Host $SourceDatabase -ForegroundColor DarkGreen
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " Destination Server (-DestinationServers)     : " -nonewline; Write-Host ($DestinationServers -join ", ") -ForegroundColor DarkGreen
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " Destination Database (-DestinationDatabases) : " -nonewline; Write-Host ($DestinationDatabases -join ", ") -ForegroundColor DarkGreen
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " Backup Path (-BackupPath)                    : " -nonewline; Write-Host $BackupPath -ForegroundColor DarkGreen
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " Restore Data Path (-RestoreDataPath)         : " -nonewline; Write-Host $RestoreDataPath -ForegroundColor DarkGreen
Write-Host "*" -ForegroundColor Yellow -nonewline; Write-Host " Restore Log Path (-RestoreLogPath)           : " -nonewline; Write-Host $RestoreLogPath -ForegroundColor DarkGreen
if (!(Ask-YesOrNo -Message "The parameters above will be used. Are you sure you want to continue?")) {Write-Host "You have chosen to end this script execution. That's a wise decision!"; Break}

if (!(Test-ClonePrerequisites))
{
    break;
}

$db = (New-Object Microsoft.SqlServer.Management.Smo.Server $SourceServer).Databases | where-Object {$_.Name -eq $SourceDatabase}

    
$restoreDataName = $db.FileGroups["Primary"].Files[0].Name;
$restoreLogName = $db.LogFiles[0].Name;

Write-Host "Prerequisites checks completed successfully.`n" -ForegroundColor Yellow

$backupFilePath = "${BackupPath}${SourceDatabase}_Clone.bak"

Write-Host "Backing up source database ($SourceDatabase)." -ForegroundColor Yellow
Write-Host "Writing to $backupFilePath"

Backup-SqlDatabase -ServerInstance $SourceServer -Database $SourceDatabase -BackupAction Database -BackupFile $backupFilePath -CopyOnly -Initialize -Script
#Backup-SqlDatabase -ServerInstance $SourceServer -Database $SourceDatabase -BackupAction Log -BackupFile $backupFilePath -CopyOnly -Script

Backup-SqlDatabase -ServerInstance $SourceServer -Database $SourceDatabase -BackupAction Database -BackupFile $backupFilePath -CopyOnly -Initialize
#Backup-SqlDatabase -ServerInstance $SourceServer -Database $SourceDatabase -BackupAction Log -BackupFile $backupFilePath -CopyOnly

Write-Host "Restoring destination database(s)..." -ForegroundColor Yellow

for ($i=0; $i -lt $DestinationDatabases.Length; $i++)
{
    $destinationServer = $DestinationServers[$i]
    $destinationDatabase = $DestinationDatabases[$i]
    $restoreMode = "RECOVERY"

    if ($ForMirroring)
    {

        if ($i -ne 0)
        {
            $restoreMode = "NORECOVERY"        
        }

        Invoke-Sqlcmd -ServerInstance $destinationServer -QueryTimeout 0 -Query "ALTER DATABASE $destinationDatabase SET WITNESS OFF;ALTER DATABASE $destinationDatabase SET PARTNER OFF" -ErrorAction Ignore
        
    }

    Start-Job -ScriptBlock {
        Param($backupFilePath, $destinationServer, $destinationDatabase, $restoreDataName, $RestoreDataPath, $restoreLogName, $RestoreLogPath, $RestoreMode)

        Push-Location
        Import-Module SQLPS -DisableNameChecking
        Pop-Location    

        function Add-TrailingSlashToPath([string] $path)
        {    
            if (!($path -match "\\$"))
            {
                return "$path\";
            }
            return $path;
        }    

        if ($RestoreDataPath -eq 'not specified')
        {
            $RestoreDataPath = (New-Object Microsoft.SqlServer.Management.Smo.Server ${destinationServer}).Settings.DefaultFile;
        }
        $RestoreDataPath = Add-TrailingSlashToPath $RestoreDataPath ;

        if ($RestoreLogPath -eq 'not specified')
        {
            $RestoreLogPath = (New-Object Microsoft.SqlServer.Management.Smo.Server ${destinationServer}).Settings.DefaultLog;
        }
        $RestoreLogPath = Add-TrailingSlashToPath $RestoreLogPath;
                
        $restoreQuery = New-Object System.Text.StringBuilder

        $operatingDb = (New-Object Microsoft.SqlServer.Management.Smo.Server ${destinationServer}).Databases | where-Object {$_.Name -eq ${destinationDatabase} -and $_.Status -eq "Normal"}
    
        if ($operatingDb -ne $null)
        {
            "Destination exists, SINGLE_USER mode set."
            $dbExists = $true
            $restoreQuery.Append("ALTER Database [${destinationDatabase}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE") | out-null
        }
        
        $restoreQuery.AppendLine(@"
        RESTORE DATABASE [${destinationDatabase}] FROM DISK = N'$backupFilePath' WITH
            
            MOVE N'${restoreDataName}' TO N'${RestoreDataPath}${destinationDatabase}.mdf', 
            MOVE N'${restoreLogName}' TO N'${RestoreLogPath}${destinationDatabase}.ldf',
            REPLACE, $restoreMode
"@) | out-null

       # $restoreQuery.AppendLine(@"
       # RESTORE LOG [${destinationDatabase}] FROM DISK = N'$backupFilePath' WITH 
       #     FILE = 2, NOUNLOAD,
        #    $restoreMode
 # "@) | out-null

        if ($operatingDb)
        {
            $restoreQuery.Append("ALTER Database [${destinationDatabase}] SET MULTI_USER") | out-null
        }

        try {
            "Restoring to ${destinationServer}/${destinationDatabase} starting."
            $restoreQuery.ToString()
            Invoke-Sqlcmd -ServerInstance $SourceServer -QueryTimeout 0 -Query $restoreQuery.ToString()
        }
        catch {
            # Print warning that the restore failed, could just throw exception to halt the script.
            $errorMessage = $_.Exception.Message
	        "        ERROR: Restoring $db failed!"
	        "		$errorMessage"
        }

        Write-Host "Restoring to ${destinationServer}/${destinationDatabase} complete." -ForegroundColor Yellow
    } -ArgumentList $backupFilePath, $destinationServer, $destinationDatabase, $restoreDataName, $RestoreDataPath, $restoreLogName, $RestoreLogPath, $RestoreMode
}

Write-Host 
Write-Host "Waiting for databases to finish restoring on the destination servers..."

do {  
    foreach ($jobId in (Get-Job).Id) {
        $update = Receive-Job -Id $jobId
        if ($update -ne $null)
        {
            Write-Host 
            Write-Host "Job $jobId output:" -ForegroundColor Yellow
            Write-Host $update
        }
    }
    Start-Sleep -s 3       
}
while ((Get-Job | Where-Object {$_.State -eq "Running"}).Count -gt 0)

foreach ($jobId in (Get-Job).Id) {
    Receive-Job -Id $jobId
    Remove-Job -Id $jobId -ErrorAction SilentlyContinue
}

#Remove-Item -Path $backupFilePath