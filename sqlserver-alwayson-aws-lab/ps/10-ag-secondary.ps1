# Secondary node only: join the AG and allow automatic seeding
$done = $false
for ($i = 0; $i -lt 12; $i++) {
    try {
        Q "ALTER AVAILABILITY GROUP [$AgName] JOIN"
        $done = $true; break
    } catch { Write-Output "Retrying JOIN: $($_.Exception.Message)"; Start-Sleep 15 }
}
if (-not $done) { throw "$Node2 could not join the AG" }
Q "ALTER AVAILABILITY GROUP [$AgName] GRANT CREATE ANY DATABASE"
Write-Output "$Node2 joined $AgName"
