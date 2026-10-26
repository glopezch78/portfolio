if ($env:COMPUTERNAME -ne $DcName) { Rename-Computer -NewName $DcName -Force }
Write-Output "Computer renamed to $DcName (reboot pending)"
