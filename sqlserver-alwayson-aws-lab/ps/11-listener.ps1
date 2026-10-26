# Primary node only: multi-subnet listener (one IP per subnet)
Q "IF NOT EXISTS (SELECT 1 FROM sys.availability_group_listeners WHERE dns_name = '$ListenerName') ALTER AVAILABILITY GROUP [$AgName] ADD LISTENER N'$ListenerName' (WITH IP ((N'10.0.1.51', N'255.255.255.0'), (N'10.0.2.51', N'255.255.255.0')), PORT = 1433)"

# Wait until the database is synchronized on the secondary
for ($i = 0; $i -lt 30; $i++) {
    $n = (Q "SELECT COUNT(*) AS n FROM sys.dm_hadr_database_replica_states WHERE synchronization_state_desc IN ('SYNCHRONIZED','SYNCHRONIZING') AND is_local = 0").n
    if ($n -ge 1) { break }
    Start-Sleep 10
}
Write-Output "Listener $ListenerName created. Synchronized replicas: $n"
