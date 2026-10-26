# SQLNODE1 only: sample database + availability group
Import-Module FailoverClusters

# A previous failed attempt can leave an orphan AG1 role in the cluster: remove it
$agInSql = Q "SELECT name FROM sys.availability_groups WHERE name = 'AG1'"
if (-not $agInSql) {
    $g = Get-ClusterGroup -Name AG1 -ErrorAction SilentlyContinue
    if ($g) { Write-Output 'Removing orphan AG1 role from the cluster'; Remove-ClusterGroup -Name AG1 -RemoveResources -Force }
}

Q "IF DB_ID('LabDB') IS NULL CREATE DATABASE LabDB"
Q "ALTER DATABASE LabDB SET RECOVERY FULL"
Q "BACKUP DATABASE LabDB TO DISK = 'NUL' WITH INIT"
Q "IF OBJECT_ID('LabDB.dbo.Heartbeat') IS NULL CREATE TABLE LabDB.dbo.Heartbeat (id int IDENTITY PRIMARY KEY, node sysname DEFAULT @@SERVERNAME, ts datetime2 DEFAULT SYSUTCDATETIME())"
Q "INSERT LabDB.dbo.Heartbeat DEFAULT VALUES"

Q @"
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = 'AG1')
CREATE AVAILABILITY GROUP [AG1]
FOR DATABASE [LabDB]
REPLICA ON
  N'SQLNODE1' WITH (ENDPOINT_URL = N'TCP://SQLNODE1.${Domain}:5022',
                    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = AUTOMATIC, SEEDING_MODE = AUTOMATIC),
  N'SQLNODE2' WITH (ENDPOINT_URL = N'TCP://SQLNODE2.${Domain}:5022',
                    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = AUTOMATIC, SEEDING_MODE = AUTOMATIC)
"@
Write-Output 'AG1 created on SQLNODE1'
