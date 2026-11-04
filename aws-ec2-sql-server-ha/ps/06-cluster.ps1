Import-Module FailoverClusters

# Wait until $Node2 is resolvable and reachable
$ok = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        Resolve-DnsName "$Node2.$Domain" -ErrorAction Stop | Out-Null
        if ((Test-NetConnection "$Node2.$Domain" -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded) { $ok = $true; break }
    } catch { }
    Start-Sleep 10
}
if (-not $ok) { throw "$Node2 is not reachable" }

# Create the cluster only if it does not exist yet (makes the step re-runnable).
# Multi-subnet cluster: one static IP per subnet.
$exists = $false
try { Get-Cluster -ErrorAction Stop | Out-Null; $exists = $true } catch { }
if (-not $exists) {
    New-Cluster -Name $ClusterName -Node $Node1, $Node2 -StaticAddress 10.0.1.50, 10.0.2.50 -NoStorage | Out-Null
}

# Quorum with a file share witness. The local cluster is used (no -Cluster name)
# because the cluster DNS record can take a while to appear.
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
    try {
        Set-ClusterQuorum -FileShareWitness "\\$DcName\witness" -ErrorAction Stop | Out-Null
        $ok = $true; break
    } catch { Start-Sleep 15 }
}
if (-not $ok) { throw 'Could not configure the quorum' }
Get-ClusterNode | Format-Table Name, State | Out-String
