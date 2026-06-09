<#
    Registra-Task.ps1  (v2)
    Crea DUE task pianificati:
      1) "Backup Sviluppo E to J"      -> backup pianificato (12:30 e 20:00) con guardia su J:
      2) "Backup Sviluppo - Watcher J" -> resta in ascolto e copia appena J: viene collegato
    DA ESEGUIRE UNA SOLA VOLTA, in PowerShell come Amministratore.
#>

$ScriptDir     = 'C:\Scripts\sync-dev'
$BackupScript  = Join-Path $ScriptDir 'Backup-Sviluppo.ps1'
$WatcherScript = Join-Path $ScriptDir 'Watcher-Backup.ps1'

# ====================================================================
# Task 1 - Backup pianificato (la guardia interna gestisce J: assente)
# ====================================================================
$Action1 = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$BackupScript`""

# Due esecuzioni al giorno. Per una sola, lascia solo $T1 e togli ", $T2".
$T1 = New-ScheduledTaskTrigger -Daily -At 12:30
$T2 = New-ScheduledTaskTrigger -Daily -At 20:00

$Set1 = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 3)

Register-ScheduledTask `
    -TaskName 'Backup Sviluppo E to J' `
    -Description 'Mirror locale E:\ -> J:\backup-sviluppo (robocopy)' `
    -Action $Action1 -Trigger $T1, $T2 -Settings $Set1 `
    -User 'SYSTEM' -Force

# ====================================================================
# Task 2 - Watcher: lancia il backup quando J: viene collegato
# ====================================================================
$Action2 = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatcherScript`""

$T3 = New-ScheduledTaskTrigger -AtStartup

$Set2 = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName 'Backup Sviluppo - Watcher J' `
    -Description 'Avvia il backup quando il disco J: viene collegato' `
    -Action $Action2 -Trigger $T3 -Settings $Set2 `
    -User 'SYSTEM' -Force

Write-Host "`nFatto. Due task creati. Avvio subito il watcher senza riavviare..."
Start-ScheduledTask -TaskName 'Backup Sviluppo - Watcher J'
