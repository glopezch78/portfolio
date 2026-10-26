# SQLNODE2 only: join the AG and allow automatic seeding
$done = $false
for ($i = 0; $i -lt 12; $i++) {
    try {
        Q 'ALTER AVAILABILITY GROUP [AG1] JOIN'
        $done = $true; break
    } catch { Write-Output "Retrying JOIN: $($_.Exception.Message)"; Start-Sleep 15 }
}
if (-not $done) { throw 'SQLNODE2 could not join the AG' }
Q 'ALTER AVAILABILITY GROUP [AG1] GRANT CREATE ANY DATABASE'
Write-Output 'SQLNODE2 joined AG1'
