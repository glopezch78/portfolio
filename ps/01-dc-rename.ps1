if ($env:COMPUTERNAME -ne 'DC01') { Rename-Computer -NewName DC01 -Force }
Write-Output 'Computer renamed to DC01 (reboot pending)'
