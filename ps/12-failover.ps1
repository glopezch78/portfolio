# Runs on both nodes; only the SECONDARY acts
$role = (Q 'SELECT role_desc FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1').role_desc
if ($role -eq 'SECONDARY') {
    Q 'ALTER AVAILABILITY GROUP [AG1] FAILOVER'
    Write-Output "Failover executed: $env:COMPUTERNAME is now PRIMARY"
} else {
    Write-Output "$env:COMPUTERNAME is $role, nothing to do"
}
