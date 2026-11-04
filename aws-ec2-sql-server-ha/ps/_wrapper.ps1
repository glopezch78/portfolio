$ErrorActionPreference = 'Stop'
$mode = '__MODE__'
$d = 'C:\lab'
New-Item $d -ItemType Directory -Force | Out-Null
$f = "$d\step.ps1"; $log = "$d\step.log"; $rc = "$d\step.rc"; $runner = "$d\run.ps1"
[IO.File]::WriteAllBytes($f, [Convert]::FromBase64String('__B64__'))
$runnerCode = @'
param($f, $log, $rc)
try { & $f *> $log; Set-Content $rc 0 } catch { ($_ | Out-String) | Add-Content $log; Set-Content $rc 1 }
'@
Set-Content $runner $runnerCode
Remove-Item $log, $rc -ErrorAction SilentlyContinue

if ($mode -eq 'admin') {
    # Run the step as the domain administrator through a scheduled task.
    # This avoids Kerberos double-hop problems that happen with remoting.
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $runner -f $f -log $log -rc $rc"
    Register-ScheduledTask -TaskName 'labstep' -Action $act -User '__NETBIOS__\Administrator' -Password '__PWD__' -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName 'labstep'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $idle = 0
    while (-not (Test-Path $rc)) {
        Start-Sleep 5
        if ((Get-ScheduledTask -TaskName 'labstep').State -eq 'Ready') { $idle++ } else { $idle = 0 }
        if ($idle -gt 8) {
            $r = (Get-ScheduledTaskInfo -TaskName 'labstep').LastTaskResult
            Unregister-ScheduledTask -TaskName 'labstep' -Confirm:$false
            throw "The task ended without a result (LastTaskResult=$r). Check the password / domain."
        }
        if ($sw.Elapsed.TotalMinutes -gt __TIMEOUT__) { throw 'Timed out waiting for the step' }
    }
    Unregister-ScheduledTask -TaskName 'labstep' -Confirm:$false
} else {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -f $f -log $log -rc $rc
}

if (Test-Path $log) { Get-Content $log }
if ((Get-Content $rc).Trim() -ne '0') { throw 'The step failed (see output above)' }
