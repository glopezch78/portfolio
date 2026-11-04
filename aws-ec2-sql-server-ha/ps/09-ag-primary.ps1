# Primary node only: sample database + availability group
Import-Module FailoverClusters

# A previous failed attempt can leave an orphan AG role in the cluster: remove it
$agInSql = Q "SELECT name FROM sys.availability_groups WHERE name = '$AgName'"
if (-not $agInSql) {
    $g = Get-ClusterGroup -Name $AgName -ErrorAction SilentlyContinue
    if ($g) { Write-Output 'Removing orphan AG role from the cluster'; Remove-ClusterGroup -Name $AgName -RemoveResources -Force }
}

Q "IF DB_ID('LabDB') IS NULL CREATE DATABASE LabDB"
Q "ALTER DATABASE LabDB SET RECOVERY FULL"
Q "BACKUP DATABASE LabDB TO DISK = 'NUL' WITH INIT"
Q "IF OBJECT_ID('LabDB.dbo.Heartbeat') IS NULL CREATE TABLE LabDB.dbo.Heartbeat (id int IDENTITY PRIMARY KEY, node sysname DEFAULT @@SERVERNAME, ts datetime2 DEFAULT SYSUTCDATETIME())"
Q "INSERT LabDB.dbo.Heartbeat DEFAULT VALUES"

Q @"
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = '$AgName')
CREATE AVAILABILITY GROUP [$AgName]
FOR DATABASE [LabDB]
REPLICA ON
  N'$Node1' WITH (ENDPOINT_URL = N'TCP://$Node1.${Domain}:5022',
                    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = AUTOMATIC, SEEDING_MODE = AUTOMATIC),
  N'$Node2' WITH (ENDPOINT_URL = N'TCP://$Node2.${Domain}:5022',
                    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = AUTOMATIC, SEEDING_MODE = AUTOMATIC)
"@
Write-Output "$AgName created on $Node1"
