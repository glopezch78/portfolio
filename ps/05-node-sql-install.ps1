[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$d = 'C:\sqlsetup'
New-Item $d -ItemType Directory -Force | Out-Null

# --- Installation media: SQL Server Developer ISO from a pre-signed URL ---
# (Microsoft's SSEI bootstrapper hangs when run non-interactively through SSM, so it is not used.)
$iso = Get-ChildItem $d -Filter *.iso -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $iso) {
    if (-not $SqlIsoUrl) { throw 'SQL_ISO_URL is empty. Export a pre-signed URL of the SQL Server Developer ISO and run: ./sqlag-lab.sh resume 7' }
    Invoke-WebRequest $SqlIsoUrl -OutFile "$d\sql.iso" -UseBasicParsing
    $iso = Get-ChildItem $d -Filter *.iso | Select-Object -First 1
    if (-not $iso -or $iso.Length -lt 500MB) { throw 'The downloaded ISO is missing or too small. Check SQL_ISO_URL.' }
}

# --- Install the database engine (mixed mode so you can use sa from SSMS on your PC) ---
$img = Mount-DiskImage -ImagePath $iso.FullName -PassThru
$drv = ($img | Get-Volume).DriveLetter
$setupArgs = @(
    '/Q', '/IACCEPTSQLSERVERLICENSETERMS', '/ACTION=Install', '/FEATURES=SQLENGINE',
    '/INSTANCENAME=MSSQLSERVER', "/SQLSYSADMINACCOUNTS=`"$Netbios\Administrator`"",
    '/SECURITYMODE=SQL', "/SAPWD=`"$LabPwd`"", '/TCPENABLED=1', '/UPDATEENABLED=0'
)
$p = Start-Process "${drv}:\setup.exe" -ArgumentList $setupArgs -Wait -PassThru
Dismount-DiskImage -ImagePath $iso.FullName | Out-Null
if ($p.ExitCode -notin 0, 3010) { throw "SQL Server setup failed (exit code $($p.ExitCode)). See C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log" }

# --- SqlServer PowerShell module (Invoke-Sqlcmd, Enable-SqlAlwaysOn) ---
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module SqlServer -Force -AllowClobber

# --- Firewall ---
New-NetFirewallRule -DisplayName 'SQL 1433'        -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow | Out-Null
New-NetFirewallRule -DisplayName 'SQL AG endpoint' -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow | Out-Null
Write-Output "SQL Server installed on $env:COMPUTERNAME (reboot pending)"
