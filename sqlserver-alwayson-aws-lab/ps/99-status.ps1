Write-Output "===== $env:COMPUTERNAME ====="
Write-Output 'Cluster nodes:'
Get-ClusterNode | Format-Table Name, State | Out-String
Write-Output 'Availability group replicas (role / connection / health):'
Q "SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc, ars.synchronization_health_desc FROM sys.availability_replicas ar JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id" | Format-Table | Out-String
Write-Output 'Listener test (MultiSubnetFailover):'
try {
    Invoke-Sqlcmd -ConnectionString "Server=tcp:$ListenerName,1433;Database=LabDB;Integrated Security=True;MultiSubnetFailover=True;TrustServerCertificate=True" `
        -Query 'SELECT @@SERVERNAME AS served_by, COUNT(*) AS rows_in_heartbeat FROM dbo.Heartbeat' | Format-Table | Out-String
} catch { Write-Output "Listener not answering yet: $($_.Exception.Message)" }
