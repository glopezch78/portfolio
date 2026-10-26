$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '10.0.*' } | Select-Object -First 1).IPAddress
$newName = if ($ip -eq '10.0.1.20') { $Node1 } else { $Node2 }

# Use the domain controller as DNS server
$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $DcIp
Clear-DnsClientCache

# Wait until the domain is reachable
$ok = $false
for ($i = 0; $i -lt 40; $i++) {
    try {
        Resolve-DnsName $Domain -Server $DcIp -ErrorAction Stop | Out-Null
        if ((Test-NetConnection $DcIp -Port 389 -WarningAction SilentlyContinue).TcpTestSucceeded) { $ok = $true; break }
    } catch { }
    Start-Sleep 15
}
if (-not $ok) { throw 'The domain is not reachable' }

Install-WindowsFeature Failover-Clustering -IncludeManagementTools | Out-Null
$cred = New-Object System.Management.Automation.PSCredential("$Netbios\Administrator", (ConvertTo-SecureString $LabPwd -AsPlainText -Force))
Add-Computer -DomainName $Domain -NewName $newName -Credential $cred -Force
Write-Output "$newName joined to $Domain (reboot pending)"
