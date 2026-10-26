# The cluster computer object ($ClusterName$) must be able to create the listener's computer object in AD
$dn = (Get-ADDomain).ComputersContainer
dsacls $dn /G ($Netbios + '\' + $ClusterName + '$:CC;computer') | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'dsacls failed' }
Write-Output "Create-computer-object permission granted to $ClusterName$"
