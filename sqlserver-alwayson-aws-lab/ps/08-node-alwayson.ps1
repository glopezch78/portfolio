Import-Module SqlServer

# Enable Always On (the node must already be a member of the cluster)
try {
    Enable-SqlAlwaysOn -ServerInstance $env:COMPUTERNAME -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Output "Enable-SqlAlwaysOn failed ($($_.Exception.Message)); falling back to the registry"
    $inst = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').MSSQLSERVER
    $key = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$inst\MSSQLServer\HADR"
    if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
    Set-ItemProperty $key -Name HADR_ENABLED -Value 1 -Type DWord
    Restart-Service MSSQLSERVER -Force
}
Wait-Sql
$hadr = (Q "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS v").v
if ($hadr -ne 1) { throw 'Always On was not enabled' }

# The cluster connects to SQL Server as NT AUTHORITY\SYSTEM (health detection).
# Without these permissions the AG never comes online (error 41131).
Q "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'NT AUTHORITY\SYSTEM') CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS"
Q "GRANT ALTER ANY AVAILABILITY GROUP TO [NT AUTHORITY\SYSTEM]"
Q "GRANT CONNECT SQL TO [NT AUTHORITY\SYSTEM]"
Q "GRANT VIEW SERVER STATE TO [NT AUTHORITY\SYSTEM]"

# Database mirroring endpoint + permission for the other node's machine account
$other = if ($env:COMPUTERNAME -eq $Node1) { $Node2 } else { $Node1 }
$login = "$Netbios\$other`$"
Q "IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name = 'hadr_endpoint') CREATE ENDPOINT hadr_endpoint STATE = STARTED AS TCP (LISTENER_PORT = 5022) FOR DATABASE_MIRRORING (ROLE = ALL, ENCRYPTION = REQUIRED ALGORITHM AES)"
Q "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$login') CREATE LOGIN [$login] FROM WINDOWS"
Q "GRANT CONNECT ON ENDPOINT::hadr_endpoint TO [$login]"
Write-Output "$env:COMPUTERNAME : Always On enabled, SYSTEM permissions granted, endpoint ready, access granted to $login"
