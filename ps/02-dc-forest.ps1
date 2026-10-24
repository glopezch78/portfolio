Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
$sp = ConvertTo-SecureString $LabPwd -AsPlainText -Force
Install-ADDSForest -DomainName $Domain -DomainNetbiosName $Netbios `
    -SafeModeAdministratorPassword $sp -InstallDns -NoRebootOnCompletion -Force | Out-Null
Write-Output "Forest $Domain created (reboot pending)"
