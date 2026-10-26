# Set the local Administrator password (it becomes the domain Administrator password after promotion)
net user Administrator $LabPwd | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not set the Administrator password' }
Write-Output 'Administrator password set'
