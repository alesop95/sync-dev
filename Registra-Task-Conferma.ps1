<#
    Registra-Task-Conferma.ps1
    Crea il task "Backup Sviluppo (con conferma)" che agli orari previsti
    mostra il pop-up di conferma nella sessione dell'utente loggato.
    DA ESEGUIRE UNA SOLA VOLTA, in PowerShell come Amministratore (con il TUO account).
#>

$ConfirmScript = Join-Path $PSScriptRoot 'Backup-Conferma.ps1'

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ConfirmScript`""

# Due orari al giorno. Per uno solo, lascia solo $T1 e togli ", $T2".
$T1 = New-ScheduledTaskTrigger -Daily -At 12:30
$T2 = New-ScheduledTaskTrigger -Daily -At 17:40

# Esecuzione INTERATTIVA nella sessione dell'utente loggato: indispensabile per il pop-up.
# Se alcuni file non venissero copiati per permessi, cambia -RunLevel in Highest.
$Principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

$Settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 3)

Register-ScheduledTask `
    -TaskName 'Backup Sviluppo (con conferma)' `
    -Description 'Pop-up di conferma; se confermato e disco/sorgente validi, esegue lo snapshot datato' `
    -Action $Action -Trigger $T1, $T2 -Principal $Principal -Settings $Settings -Force

Write-Host "`nTask 'Backup Sviluppo (con conferma)' creato."

# --- Disattiva la vecchia modalita' automatica (togli il commento se l'avevi creata) ---
# Unregister-ScheduledTask -TaskName 'Backup Sviluppo E to J' -Confirm:$false
# Unregister-ScheduledTask -TaskName 'Backup Sviluppo - Watcher J' -Confirm:$false
