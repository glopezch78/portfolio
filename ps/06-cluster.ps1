Import-Module FailoverClusters

# Wait until SQLNODE2 is resolvable and reachable
$ok = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        Resolve-DnsName "SQLNODE2.$Domain" -ErrorAction Stop | Out-Null
        if ((Test-NetConnection "SQLNODE2.$Domain" -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded) { $ok = $true; break }
    } catch { }
    Start-Sleep 10
}
if (-not $ok) { throw 'SQLNODE2 is not reachable' }

# Create the cluster only if it does not exist yet (makes the step re-runnable).
# Multi-subnet cluster: one static IP per subnet.
$exists = $false
try { Get-Cluster -ErrorAction Stop | Out-Null; $exists = $true } catch { }
if (-not $exists) {
    New-Cluster -Name SQLCL -Node SQLNODE1, SQLNODE2 -StaticAddress 10.0.1.50, 10.0.2.50 -NoStorage | Out-Null
}

# Quorum with a file share witness. The local cluster is used (no -Cluster name)
# because the SQLCL DNS record can take a while to appear.
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
    try {
        Set-ClusterQuorum -FileShareWitness "\\DC01\witness" -ErrorAction Stop | Out-Null
        $ok = $true; break
    } catch { Start-Sleep 15 }
}
if (-not $ok) { throw 'Could not configure the quorum' }
Get-ClusterNode | Format-Table Name, State | Out-String
