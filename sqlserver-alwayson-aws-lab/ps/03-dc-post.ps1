# Wait until Active Directory answers
$ok = $false
for ($i = 0; $i -lt 30; $i++) {
    try { Get-ADDomain | Out-Null; $ok = $true; break } catch { Start-Sleep 20 }
}
if (-not $ok) { throw 'Active Directory is not responding' }

# DNS: forward external names to the VPC resolver (so the nodes can reach the internet and SSM)
if (-not (Get-DnsServerForwarder).IPAddress) { Add-DnsServerForwarder -IPAddress 169.254.169.253 }
$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $DcIp
Clear-DnsClientCache
ipconfig /registerdns | Out-Null
nltest /dsregdns | Out-Null

# File share witness (quorum) for the 2-node cluster
New-Item C:\witness -ItemType Directory -Force | Out-Null
if (-not (Get-SmbShare -Name witness -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name witness -Path C:\witness -FullAccess "$Netbios\Domain Admins", "$Netbios\Domain Computers" | Out-Null
}
icacls C:\witness /grant "${Netbios}\Domain Computers:(OI)(CI)F" "${Netbios}\Domain Admins:(OI)(CI)F" | Out-Null
Write-Output 'DC ready: DNS forwarder configured and \\DC01\witness share created'
