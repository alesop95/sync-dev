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
    $w.Popup("Configurazione non caricata: Config-sync-dev.ps1 risulta bloccato o assente.`n`nEsegui in PowerShell:`nGet-ChildItem '$PSScriptRoot\*.ps1' | Unblock-File", 0, "Backup Sviluppo - ERRORE", 16 + 4096) | Out-Null
    return
}

$BackupScript = Join-Path $PSScriptRoot 'Backup-Sviluppo.ps1'
$Timeout      = 120   # secondi prima che il pop-up si chiuda da solo (= "No")

$wshell = New-Object -ComObject WScript.Shell

# 4=Si'/No, 32=domanda, 4096=system modal. Ritorni: 6=Si', 7=No, -1=timeout
$msg = "E' l'ora del backup dei progetti di sviluppo.`n`n" +
       "Verifica che il disco di backup ($ExpectedDiskModel) sia collegato come ${ExpectedDriveLetter}:, poi conferma.`n`n" +
       "Attendi l'esito finale prima di richiedere la rimozione sicura: dopo la copia restano verifica e pulizia.`n`n" +
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
        $wshell.Popup("Copia, verifica e pulizia completate correttamente.`nPuoi richiedere la rimozione sicura del disco da Windows.", 10, "Backup Sviluppo", 64 + 4096)
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
    104 {
        $wshell.Popup("Il volume ${ExpectedDriveLetter}: non e' sano o il suo stato non e' verificabile.`nCopia e pulizia BLOCCATE. Controlla e ripara il disco, poi rilancia.`n`nDettagli locali: $PSScriptRoot\_logs\BACKUP-ERRORE.txt", 0, "Backup Sviluppo - VOLUME DA CONTROLLARE", 16 + 4096)
    }
    105 {
        $wshell.Popup("Il backup non si e' concluso: errore durante verifica, scrittura dei log o pulizia.`nI residui di cancellazioni interrotte verranno ripresi al prossimo backup con volume sano.`n`nDettagli locali: $PSScriptRoot\_logs\BACKUP-ERRORE.txt", 0, "Backup Sviluppo - NON CONCLUSO", 48 + 4096)
    }
    106 {
        $wshell.Popup("Un backup e' gia' in corso. Attendi il suo esito prima di richiedere la rimozione sicura del disco.", 15, "Backup Sviluppo", 48 + 4096)
    }
    107 {
        # Spazio insufficiente: il disco non e' stato toccato. Si blocca PRIMA di
        # scrivere perche' un volume portato a saturazione non si limita a far
        # fallire la copia: impedisce anche la pulizia che libererebbe spazio.
        $wshell.Popup("Spazio insufficiente sul disco di backup ${ExpectedDriveLetter}:.`nBackup BLOCCATO: non e' stato scritto nulla e le copie precedenti sono intatte.`n`nLibera spazio su ${ExpectedDriveLetter}: e rilancia.`n`nDettagli: $PSScriptRoot\_logs\BACKUP-ERRORE.txt", 0, "Backup Sviluppo - SPAZIO INSUFFICIENTE", 48 + 4096)
    }
    108 {
        # Non e' un problema del disco di backup: il messaggio deve dirlo subito,
        # altrimenti si perde tempo a controllare J:, che di solito sta bene.
        $wshell.Popup("Windows non risponde piu' alle interrogazioni sui dischi, quindi il backup non ha potuto verificare ${ExpectedDriveLetter}: e si e' fermato.`n`nNON e' stato scritto nulla: le copie precedenti sono intatte.`n`nDi solito la causa e' un ALTRO dispositivo collegato che ha smesso di rispondere (tipicamente una chiavetta o un disco USB). Scollegalo o ricollegalo, poi rilancia il backup.`n`nIl rapporto dice su quale disco Windows sta ripetendo le operazioni:`n$PSScriptRoot\_logs\BACKUP-ERRORE.txt", 0, "Backup Sviluppo - DISCHI NON INTERROGABILI", 48 + 4096)
    }
    default {
        # Codice >= 8 = copia con file mancanti: l'engine ha eliminato lo snapshot
        # difettoso (resta solo l'ultima copia completa) e ha scritto in _logs il
        # rapporto con gli errori e i comandi per rilanciare.
        $report = Join-Path $BackupRoot '_logs\BACKUP-FALLITO-RILANCIARE.txt'
        if ($code -ge 8 -and (Test-Path -LiteralPath $report)) {
            # 4=Si'/No, 48=avviso; timeout 0 = resta aperto finche' non si risponde
            $msg = "Backup terminato con errori (codice $code): alcuni file non sono stati copiati.`n`n" +
                   "Il rapporto indica se la copia difettosa e' stata scartata o conservata in assenza di una copia completa.`n`n" +
                   "Il rapporto con i file non copiati e i comandi per rilanciare subito e' in:`n$report`n`n" +
                   "Apro il rapporto adesso?"
            if ($wshell.Popup($msg, 0, "Backup Sviluppo - DA RILANCIARE", 4 + 48 + 4096) -eq 6) {
                Start-Process notepad.exe -ArgumentList "`"$report`""
            }
        } else {
            $wshell.Popup("Backup terminato con errori (codice $code).`nControlla i log in $BackupRoot\_logs.", 30, "Backup Sviluppo", 48 + 4096)
        }
    }
}
