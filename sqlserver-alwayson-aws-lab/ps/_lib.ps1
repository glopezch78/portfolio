function Q([string]$q) {
    Import-Module SqlServer -ErrorAction Stop
    Invoke-Sqlcmd -ServerInstance $env:COMPUTERNAME -Query $q -TrustServerCertificate -QueryTimeout 600 -ErrorAction Stop
}
function Wait-Sql {
    for ($i = 0; $i -lt 30; $i++) {
        try { Q 'SELECT 1' | Out-Null; return } catch { Start-Sleep 10 }
    }
    throw 'SQL Server is not responding'
}
