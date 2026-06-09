<#
    Backup-Conferma.ps1
    Mostra il pop-up di conferma; su "Si'" richiama l'engine e mostra l'esito o l'alert.
    Parametri condivisi in Config-sync-dev.ps1.
    Eseguito dal task in modalita' INTERATTIVA (utente loggato), altrimenti la finestra non appare.
#>

. (Join-Path $PSScriptRoot 'Config-sync-dev.ps1')

# Se la configurazione non si e' caricata (file bloccato o assente), avvisa ed esci.
if (-not $ExpectedDriveLetter) {
    $w = New-Object -ComObject WScript.Shell
    $w.Popup("Configurazione non caricata: Config-sync-dev.ps1 risulta bloccato o assente.`n`nEsegui in PowerShell:`nGet-ChildItem C:\Scripts\sync-dev\*.ps1 | Unblock-File", 0, "Backup Sviluppo - ERRORE", 16 + 4096) | Out-Null
    return
}

$BackupScript = Join-Path $PSScriptRoot 'Backup-Sviluppo.ps1'
$Timeout      = 120   # secondi prima che il pop-up si chiuda da solo (= "No")

$wshell = New-Object -ComObject WScript.Shell

# 4=Si'/No, 32=domanda, 4096=system modal. Ritorni: 6=Si', 7=No, -1=timeout
$msg = "E' l'ora del backup dei progetti di sviluppo.`n`n" +
       "Verifica che il disco di backup ($ExpectedDiskModel) sia collegato come ${ExpectedDriveLetter}:, poi conferma.`n`n" +
       "Eseguo il backup adesso?"
$ans = $wshell.Popup($msg, $Timeout, "Backup Sviluppo", 4 + 32 + 4096)
if ($ans -ne 6) { return }

# Esegue l'engine in un processo separato e ne legge il codice di uscita
$p = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -WindowStyle Hidden `
     -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $BackupScript)
$code = $p.ExitCode

switch ($code) {
    0 {
        # 64=info; si chiude da solo dopo 10s
        $wshell.Popup("Backup completato correttamente.", 10, "Backup Sviluppo", 64 + 4096)
    }
    101 {
        # disco con lettera attesa ma dispositivo sbagliato. 16=stop, timeout 0 = resta aperto
        $wshell.Popup("Il disco ${ExpectedDriveLetter}: collegato NON e' il dispositivo atteso ($ExpectedDiskModel).`nBackup BLOCCATO: nessun file copiato.", 0, "Backup Sviluppo - BLOCCATO", 16 + 4096)
    }
    103 {
        # nessun disco con la lettera attesa
        $wshell.Popup("Il disco di backup atteso ($ExpectedDiskModel) non risulta collegato come ${ExpectedDriveLetter}:.`nBackup BLOCCATO.", 0, "Backup Sviluppo - BLOCCATO", 16 + 4096)
    }
    102 {
        # sorgente non rilevata. 48=avviso
        $wshell.Popup("La $SourceLabel ($Source) non e' rilevata.`nBackup BLOCCATO. Puoi impostare un'altra sorgente in Config-sync-dev.ps1.", 0, "Backup Sviluppo - BLOCCATO", 48 + 4096)
    }
    default {
        $wshell.Popup("Backup terminato con errori (codice $code).`nControlla i log in $BackupRoot\_logs.", 30, "Backup Sviluppo", 48 + 4096)
    }
}
