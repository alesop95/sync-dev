<#
    Backup-Sviluppo.ps1
    Snapshot datati con retention. Parametri e verifiche in Config-sync-dev.ps1.
    Prima di copiare verifica che:
      1) il disco di backup sia ESATTAMENTE quello atteso (modello e, se impostato, serial);
      2) il volume sia sano e operativo;
      3) la sorgente sia presente.
    Se una verifica fallisce, NON copia e NON cancella nulla, ed esce con un codice dedicato.
    Cancella SOLO dentro $BackupRoot. La sorgente non viene MAI toccata.
#>

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Config-sync-dev.ps1')

# Se la configurazione non si e' caricata (file bloccato o assente), esci con messaggio.
if (-not $BackupRoot) {
    Write-Host "Configurazione non caricata: esegui Unblock-File sui .ps1 della cartella."
    exit 1
}

$LogDir = Join-Path $BackupRoot '_logs'

# Nome del file sentinella che marca uno snapshot incompleto. Vive dentro la
# cartella dello snapshot, quindi la marcatura sopravvive alla fine dello script:
# e' la memoria che le esecuzioni successive leggono per sapere cosa buttare.
$MarkerName = '_SNAPSHOT-INCOMPLETO.txt'

# Rapporto scritto in _logs quando la copia fallisce: spiega cosa e' successo e
# come rilanciare subito. Viene eliminato dal primo backup riuscito.
$FailReportName = 'BACKUP-FALLITO-RILANCIARE.txt'

# Elenco degli snapshot presenti (cartelle AAAA-MM-GG\HH-mm-ss), con il giorno di
# appartenenza e l'indicazione se sono marcati come incompleti.
function Get-Snapshots {
    $pending = @(Get-PendingCleanup)
    Get-ChildItem -LiteralPath $BackupRoot -Directory -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } |
        ForEach-Object {
            $dayName = $_.Name
            $null = Assert-BackupRemovalPath $_.FullName
            Get-ChildItem -LiteralPath $_.FullName -Directory -Force -ErrorAction Stop |
                Where-Object { $_.Name -match '^\d{2}-\d{2}-\d{2}$' } |
                ForEach-Object {
                    $null = Assert-BackupRemovalPath $_.FullName
                    [pscustomobject]@{
                        Day    = $dayName
                        Date   = [datetime]::ParseExact($dayName, 'yyyy-MM-dd', $null)
                        Rel    = $dayName + '\' + $_.Name
                        Path   = $_.FullName
                        Broken = (Test-Path -LiteralPath (Join-Path $_.FullName $MarkerName) -ErrorAction Stop) -or
                                 ($pending -contains ($dayName + '\' + $_.Name)) -or
                                 (($pending -contains $dayName) -and $_.FullName -ine $SnapDir)
                    }
                }
        }
}

# Recupera pulizie interrotte e copie incomplete prima di copiare, cosi' i
# residui non occupano spazio inutilmente. Occorre una copia completa da tenere.
function Clear-BackupResidues {
    $snaps = @(Get-Snapshots)
    if (@($snaps | Where-Object { -not $_.Broken }).Count -eq 0) { return }
    foreach ($relative in @(Get-PendingCleanup)) {
        $path = Assert-BackupRemovalPath (Join-Path $BackupRoot $relative)
        # Mai eliminare il giorno corrente o lo snapshot appena creato.
        if ($path -ieq $DayDir -or $path -ieq $SnapDir) { continue }
        Write-Step "Riprendo la pulizia pendente: $relative"
        Remove-TreeFast $path
        Add-Content -LiteralPath $HistoryFile -Encoding UTF8 -Value (
            '{0} | PULIZIA | {1} | residuo di cancellazione eliminato' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $relative)
    }
    foreach ($snapshot in @($snaps | Where-Object { $_.Broken -and $_.Path -ine $SnapDir })) {
        if (-not (Test-Path -LiteralPath $snapshot.Path -ErrorAction Stop)) { continue }
        Write-Step "Pulizia: elimino lo snapshot incompleto $($snapshot.Rel)"
        Remove-TreeFast $snapshot.Path
        Add-Content -LiteralPath $HistoryFile -Encoding UTF8 -Value (
            '{0} | PULIZIA | {1} | snapshot incompleto eliminato' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $snapshot.Rel)
    }
    Get-ChildItem -LiteralPath $BackupRoot -Directory -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.FullName -ine $DayDir } |
        ForEach-Object {
            if (@(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction Stop).Count -eq 0) {
                Remove-TreeFast $_.FullName
            }
        }
}

function Write-Step([string]$msg) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" }
$mutex = $null
$locked = $false
$code = 16
try {
# --- Guardia 1: il disco di backup e' quello atteso? ----------------
$dev = Test-BackupDevice
if (-not $dev.Ok) {
    Write-Host "[$(Get-Date -Format s)] BLOCCATO: $($dev.Reason)"
    if ($dev.Status -eq 'TIMEOUT') {
        # Il rapporto si scrive nei _logs del progetto e non su J:, perche' qui
        # del disco di backup non si sa ancora niente.
        Write-LocalBackupError $dev.Reason
        exit $EXIT_STORAGE_TIMEOUT
    }
    if ($dev.Status -eq 'NODISK') { exit $EXIT_DEVICE_MISSING } else { exit $EXIT_DEVICE_MISMATCH }
}

# --- Guardia 2: volume sano, prima di qualsiasi scrittura sul backup --
$volume = Test-BackupVolume
if (-not $volume.Ok) {
    Write-Step "BLOCCATO: $($volume.Reason)"
    Write-LocalBackupError $volume.Reason
    if ($volume.Status -eq 'TIMEOUT') { exit $EXIT_STORAGE_TIMEOUT }
    exit $EXIT_VOLUME_UNHEALTHY
}
$null = Assert-BackupRoot
$null = Get-CleanupJournalPath

# Da qui dispositivo, volume e percorso sono verificati.
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$HistoryFile = Join-Path $LogDir 'storico-snapshot.txt'

# --- Guardia 3: sorgente presente? ----------------------------------
$src = Test-SourceAvailable
if (-not $src.Ok) {
    $blk = '{0} | BLOCCATO | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $src.Reason
    Add-Content -LiteralPath $HistoryFile -Value $blk -Encoding UTF8
    Write-Host "[$(Get-Date -Format s)] BLOCCATO: $($src.Reason)"
    exit $EXIT_SOURCE_MISSING
}

# --- Lock anti-sovrapposizione --------------------------------------
# Un mutex "abbandonato" (processo precedente terminato a forza mentre lo teneva)
# viene comunque acquisito da WaitOne, che pero' lancia AbandonedMutexException:
# lo trattiamo come lock ottenuto invece di far fallire lo script.
$mutex = New-Object System.Threading.Mutex($false, 'Global\BackupSviluppo')
try { $locked = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $locked = $true }
if (-not $locked) { Write-Host "Backup gia' in corso. Esco."; exit $EXIT_ALREADY_RUNNING }

    $now     = Get-Date
    $DayDir  = Join-Path $BackupRoot $now.ToString('yyyy-MM-dd')
    $SnapDir = Join-Path $DayDir     $now.ToString('HH-mm-ss')
    $null = Assert-BackupRemovalPath $SnapDir
    Clear-BackupResidues

    # --- Guardia 4: c'e' spazio per il nuovo snapshot? -------------------
    # Dopo Clear-BackupResidues, che puo' aver liberato residui, e prima di
    # creare qualsiasi cartella: se lo spazio non basta il disco resta
    # esattamente com'era. Riempire il volume non produce solo un backup
    # fallito, produce uno stallo: a 0 byte liberi non si scrive piu' nemmeno
    # il registro delle pulizie, e la cancellazione che libererebbe spazio non
    # parte (2026-10-16). Un exFAT saturo per giunta si corrompe.
    $space = Test-BackupFreeSpace
    if ($space.Status -eq 'TIMEOUT') {
        Write-Step "BLOCCATO: $($space.Reason)"
        Add-Content -LiteralPath $HistoryFile -Encoding UTF8 -Value (
            '{0} | BLOCCATO | provider Storage non raggiungibile: spazio libero non verificabile' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        Write-LocalBackupError $space.Reason
        exit $EXIT_STORAGE_TIMEOUT
    }
    if (-not $space.Ok) {
        $reason = $space.Reason
        # Il blocco deve dire anche COSA togliere, altrimenti e' un vicolo cieco.
        # Caso tipico: non esiste nessuna copia completa, quindi Clear-BackupResidues
        # ha conservato uno snapshot difettoso (giustamente: meglio parziale che
        # niente) che pero' occupa lo spazio necessario a farne uno buono. La
        # scelta se sacrificarlo resta all'operatore, che qui riceve i numeri.
        $broken = @(Get-Snapshots | Where-Object { $_.Broken })
        if ($broken.Count -gt 0) {
            $recuperabile = [long]0
            foreach ($b in $broken) {
                Get-ChildItem -LiteralPath $b.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { $recuperabile += $_.Length }
            }
            $reason += "`r`nSu disco ci sono {0} snapshot INCOMPLETI che occupano circa {1:N1} GB ({2}). Sono copie troncate: se non esiste una copia completa l'engine le conserva per prudenza, ma eliminandole si libera lo spazio per una copia buona." -f `
                       $broken.Count, ($recuperabile/1GB), (($broken | ForEach-Object { $_.Rel }) -join ', ')
        }
        Write-Step "BLOCCATO: $reason"
        Add-Content -LiteralPath $HistoryFile -Encoding UTF8 -Value (
            '{0} | BLOCCATO | spazio insufficiente: liberi {1:N1} GB, servono {2:N1} GB' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ($space.FreeBytes/1GB), ($space.NeedBytes/1GB))
        Write-LocalBackupError $reason
        exit $EXIT_LOW_SPACE
    }
    Write-Step ("Spazio verificato: liberi {0:N1} GB, stimati necessari {1:N1} GB." -f `
                ($space.FreeBytes/1GB), ($space.NeedBytes/1GB))

    New-Item -ItemType Directory -Force -Path $DayDir | Out-Null
    New-Item -ItemType Directory -Path $SnapDir | Out-Null

    $LogFile = Join-Path $LogDir ("backup_" + $now.ToString('yyyyMMdd_HHmmss') + ".log")

    # Marcatura preventiva: lo snapshot nasce "incompleto" e il marcatore viene
    # tolto solo se la copia termina bene. Cosi' anche un'interruzione (Ctrl+C,
    # finestra chiusa, spegnimento) lascia lo snapshot parziale riconoscibile e
    # le esecuzioni successive non lo scambiano per una copia completa.
    $MarkerPath = Join-Path $SnapDir $MarkerName
    Set-Content -LiteralPath $MarkerPath -Encoding UTF8 -Value @(
        'SNAPSHOT INCOMPLETO: copia avviata e non conclusa (interrotta o in corso).'
        ('Data:            ' + $now.ToString('yyyy-MM-dd HH:mm:ss'))
        ('Log dettagliato: ' + (Split-Path $LogFile -Leaf))
        ''
        "Questo file e' la memoria per le esecuzioni successive: al primo backup"
        'completo lo snapshot marcato viene eliminato automaticamente.'
    )

    $RoboArgs = @(
        $Source, $SnapDir,
        '/E',
        '/XJ',
        '/MT:32',
        '/R:1','/W:2',
        '/NP','/NDL','/NFL',
        ('/LOG:' + $LogFile), '/TEE'
    )
    $RoboArgs += '/XD'; $RoboArgs += $ExcludeDirs
    $RoboArgs += 'System Volume Information'; $RoboArgs += '$RECYCLE.BIN'
    $RoboArgs += '/XF'; $RoboArgs += $ExcludeFiles

    Write-Step "Copia in corso: $Source -> $SnapDir"
    Write-Step "Di solito richiede 10-15 minuti e fino alla fine non compare altro output. Non chiudere la finestra."
    $t0 = Get-Date
    robocopy @RoboArgs
    $code = $LASTEXITCODE
    Write-Step ("Copia terminata in {0:hh\:mm\:ss} (codice robocopy {1})." -f ((Get-Date) - $t0), $code)

    # --- Declassamento degli errori benigni -----------------------------
    # Il bit 8 del codice robocopy dice "alcuni file non sono stati copiati" e da
    # solo fa scartare l'intero snapshot. Ma un file effimero sparito durante la
    # copia non e' una perdita: non esiste piu' nemmeno in origine. Il 2026-10-19
    # un prova.md di scratch, cancellato alle 17:07 e cercato alle 17:10, ha fatto
    # buttare 25,6 GB di copia buona, 168.252 file su 168.253 regolarmente copiati.
    # Il declassamento scatta SOLO se OGNI errore del log e' di quel tipo: basta un
    # errore 5 (accesso negato), 32 (file in uso) o 112 (disco pieno), o il bit 16
    # (errore grave), e lo snapshot resta difettoso esattamente come prima.
    $RoboCode   = $code
    $BenignErrs = @()
    if ($code -ge 8 -and -not ($code -band 16)) {
        $logErrs = @(Get-RobocopyLogErrors $LogFile)
        if ($logErrs.Count -gt 0) {
            $BenignErrs = @($logErrs | Where-Object { Test-VanishedSourceError $_ })
            if ($BenignErrs.Count -eq $logErrs.Count) {
                $code = $code -band (-bnot 8)
                Write-Step ("Errori benigni: {0} percors{1} spariti dalla sorgente durante la copia e assenti anche adesso. Codice robocopy {2} declassato a {3}: lo snapshot e' completo." -f `
                            $BenignErrs.Count, $(if ($BenignErrs.Count -eq 1) { 'o' } else { 'i' }), $RoboCode, $code)
                foreach ($b in $BenignErrs) { Write-Host ("    ignorato: " + $b.Path) }
            } else {
                $BenignErrs = @()
            }
        }
    }

    # --- Ripresa: seconda passata quando il log non spiega il guasto ----
    # Il declassamento qui sopra sa decidere solo se il log porta righe di
    # errore. Ma robocopy puo' contare un guasto nel riepilogo finale e non
    # scriverne niente: il 2026-10-28 la copia e' uscita con codice 11, il
    # riepilogo diceva 1 directory non riuscita su 20.945 e 0 file su 195.088,
    # e di righe ERRORE non ce n'era nessuna. Senza niente da leggere lo
    # snapshot e' stato dichiarato difettoso ed eliminato: 28,9 GB copiati bene
    # buttati per una cartella di cui non si sapra' mai il nome, e il backup
    # tornato indietro di un giorno.
    #
    # Invece di indovinare, si riprova. Una seconda passata con gli stessi
    # argomenti (/E, mai /MIR: non cancella niente) ricammina l'albero e copia
    # solo cio' che manca, quindi costa l'enumerazione e poco altro. Se torna
    # pulita, lo snapshot e' completo per constatazione e non per deduzione:
    # robocopy ha appena riguardato tutto e non ha trovato piu' niente da fare.
    # Se fallisce di nuovo, il guasto e' reale e vale il comportamento di prima.
    # Vale anche per i guasti transitori che una riga di errore ce l'hanno (il
    # file tenuto aperto un istante dall'antivirus): /R:1 e' una rete a maglie
    # larghe, una passata intera e' il tentativo serio.
    $RetryLog    = $null
    $RetryCode   = $null
    $RetryBenign = @()
    $Summary     = Get-RobocopySummary $LogFile
    if ($code -ge 8 -and $Summary.Found) {
        Write-Step ("Riepilogo robocopy: {0} directory non riuscite su {1}, {2} file non riusciti su {3}." -f `
                    $Summary.DirsFailed, $Summary.DirsTotal, $Summary.FilesFailed, $Summary.FilesTotal)
    }
    if ($code -ge 8 -and -not ($code -band 16) -and $RetryCopyOnFailure) {
        # Non si scrive su un volume che nel frattempo si e' degradato: la
        # verifica di fine copia piu' sotto fallirebbe comunque, ma questa
        # passata scriverebbe prima di arrivarci.
        $volume = Test-BackupVolume
        if (-not $volume.Ok) {
            Write-Step "Ripresa non tentata: $($volume.Reason)"
        } else {
            $RetryLog = Join-Path $LogDir ("backup_" + $now.ToString('yyyyMMdd_HHmmss') + "_ripresa.log")
            $RetryArgs = @($RoboArgs | ForEach-Object {
                if ($_ -eq ('/LOG:' + $LogFile)) { '/LOG:' + $RetryLog } else { $_ }
            })
            Write-Step "Copia con errori: seconda passata sullo stesso snapshot, copia solo cio' che manca."
            $t1 = Get-Date
            robocopy @RetryArgs
            $RetryCode = $LASTEXITCODE
            Write-Step ("Ripresa terminata in {0:hh\:mm\:ss} (codice robocopy {1})." -f ((Get-Date) - $t1), $RetryCode)
            if ($RetryCode -lt 8) {
                $code = $code -band (-bnot 8)
                Write-Step ("Ripresa pulita: non e' rimasto niente da copiare. Codice robocopy {0} declassato a {1}: lo snapshot e' completo." -f $RoboCode, $code)
            } elseif (-not ($RetryCode -band 16)) {
                # La ripresa ha fallito a sua volta, ma se tutto cio' che resta
                # sono percorsi spariti dalla sorgente vale la stessa clemenza
                # della prima passata.
                $retryErrs = @(Get-RobocopyLogErrors $RetryLog)
                if ($retryErrs.Count -gt 0) {
                    $RetryBenign = @($retryErrs | Where-Object { Test-VanishedSourceError $_ })
                    if ($RetryBenign.Count -eq $retryErrs.Count) {
                        $code = $code -band (-bnot 8)
                        Write-Step ("Ripresa: restano solo {0} percorsi spariti dalla sorgente. Codice robocopy {1} declassato a {2}: lo snapshot e' completo." -f `
                                    $RetryBenign.Count, $RoboCode, $code)
                        foreach ($b in $RetryBenign) { Write-Host ("    ignorato: " + $b.Path) }
                    } else {
                        $RetryBenign = @()
                    }
                }
            }
        }
    }

    # robocopy puo' propagare alla destinazione gli attributi della radice sorgente
    # (molte radici di volume sono Nascosto+Sistema), rendendo lo snapshot invisibile
    # in Esplora risorse pur contenendo i dati. Riportiamo le cartelle dello snapshot
    # a "directory normale".
    foreach ($d in @($DayDir, $SnapDir)) {
        $it = Get-Item -LiteralPath $d -Force -ErrorAction Stop
        if ($it) { $it.Attributes = [System.IO.FileAttributes]::Directory }
    }

    # --- Storico cumulativo (append, senza retention) ---
    Write-Step "Conteggio dei file dello snapshot per lo storico (puo' richiedere qualche minuto)..."
    $stats = Get-SnapshotFileStats $SnapDir $MarkerPath
    $count = $stats.Count
    $sizeMB = [math]::Round($stats.Bytes / 1MB, 1)
    # Una copia e' completa solo dopo un conteggio leggibile e un nuovo controllo
    # del volume. Se qualcosa fallisce, restano il marcatore e le copie precedenti.
    $volume = Test-BackupVolume
    if (-not $volume.Ok) { throw $volume.Reason }
    if ($code -lt 8) { Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction Stop }
    $rel    = $now.ToString('yyyy-MM-dd') + '\' + $now.ToString('HH-mm-ss')
    $stato  = if ($code -lt 8) { 'OK' } else { "ERRORI (codice $code) -> vedi $(Split-Path $LogFile -Leaf)" }
    $line   = '{0} | {1} | {2} | {3} file | {4} MB' -f `
              $now.ToString('yyyy-MM-dd HH:mm:ss'), $rel, $stato, $count, $sizeMB
    Add-Content -LiteralPath $HistoryFile -Value $line -Encoding UTF8
    Write-Step "Snapshot $rel | $stato | $count file | $sizeMB MB"
    # Il declassamento si annota a parte: la riga dello snapshot deve restare
    # '| OK |' secco perche' Get-LastSnapshotBytes la ritrova con quel pattern.
    if ($BenignErrs.Count -gt 0) {
        Add-Content -LiteralPath $HistoryFile -Encoding UTF8 -Value (
            '{0} | EFFIMERI | {1} | codice robocopy {2} declassato a {3}: {4} percorsi spariti durante la copia e assenti anche in origine' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $rel, $RoboCode, $code, $BenignErrs.Count)
    }
    if ($null -ne $RetryCode) {
        $esitoRipresa = if ($code -lt 8) {
            if ($RetryBenign.Count -gt 0) {
                'codice robocopy {0} declassato a {1}: restavano solo {2} percorsi spariti dalla sorgente' -f $RoboCode, $code, $RetryBenign.Count
            } else {
                'codice robocopy {0} declassato a {1}: niente piu'' da copiare' -f $RoboCode, $code
            }
        } else {
            'codice robocopy {0} confermato: la seconda passata e'' fallita a sua volta (codice {1})' -f $RoboCode, $RetryCode
        }
        Add-Content -LiteralPath $HistoryFile -Encoding UTF8 -Value (
            '{0} | RIPRESA | {1} | {2} -> vedi {3}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $rel, $esitoRipresa, (Split-Path $RetryLog -Leaf))
    }

    # --- Memoria dell'esito: marca lo snapshot incompleto ---------------
    # Codice robocopy >= 8 = la copia e' arrivata in fondo ma alcuni file non
    # sono stati copiati. Lo snapshot resta (meglio parziale che niente) ma viene
    # marcato: le esecuzioni successive sanno che non e' affidabile e lo
    # eliminano appena esiste una copia completa. Il marcatore preventivo viene
    # sovrascritto con il dettaglio dell'esito.
    if ($code -ge 8) {
        Set-Content -LiteralPath $MarkerPath -Encoding UTF8 -Value @(
            'SNAPSHOT INCOMPLETO: alcuni file non sono stati copiati.'
            ('Data:            ' + $now.ToString('yyyy-MM-dd HH:mm:ss'))
            ('Codice robocopy: ' + $code)
            ('Log dettagliato: ' + (Split-Path $LogFile -Leaf))
            ''
            'Se su disco esiste una copia completa, questo snapshot viene eliminato'
            "subito; se resta, e' perche' non esiste nessuna copia completa e verra'"
            'eliminato al primo backup completo.'
        )
        Write-Host "Snapshot marcato come incompleto (codice $code)."
    }

    Write-Step "Retention e pulizia degli snapshot vecchi o incompleti..."

    # --- Retention: conserva $RetainDays giorni SOLARI, oggi incluso (solo lato backup) ---
    # Il giorno corrente non va mai eliminato: contiene lo snapshot appena creato.
    if ($RetainDays -lt 1) { $RetainDays = 1 }
    $cutoff = $now.Date.AddDays(-($RetainDays - 1))    # data del giorno piu' vecchio da tenere

    $snaps = @(Get-Snapshots)
    $good  = @($snaps | Where-Object { -not $_.Broken })

    # Copia con errori: lo snapshot appena creato non e' affidabile, quindi la
    # finestra si allarga fino a comprendere il giorno dell'ultimo snapshot
    # completo, che resta l'unica copia buona e non va cancellata.
    if ($code -ge 8) {
        $keep = $good | Sort-Object Rel -Descending | Select-Object -First 1
        $what = 'ultimo snapshot completo'
        if (-not $keep) {
            # Nessuno snapshot completo su disco: si protegge comunque quello
            # precedente, che puo' contenere i file mancati stavolta.
            $keep = $snaps | Where-Object { $_.Path -ine $SnapDir } |
                    Sort-Object Rel -Descending | Select-Object -First 1
            $what = 'snapshot precedente (nessuno completo disponibile)'
        }
        if ($keep -and $keep.Date -lt $cutoff) {
            $cutoff = $keep.Date
            Write-Host "Copia con errori: conservo anche il giorno $($keep.Day), $what."
        }
    }

    # Pulizia della memoria: gli snapshot marcati nei tentativi precedenti vengono
    # eliminati appena esiste una copia completa, anche quando stanno nella
    # cartella-giorno corrente, dove la finestra a calendario non arriverebbe. Se
    # non esiste ancora nessuno snapshot completo non si tocca nulla: meglio una
    # copia parziale che nessuna copia.
    Clear-BackupResidues

    Get-ChildItem -LiteralPath $BackupRoot -Directory -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } |
        ForEach-Object {
            $d = [datetime]::ParseExact($_.Name, 'yyyy-MM-dd', $null)
            if ($d -lt $cutoff) {
                Write-Host "Retention: elimino il giorno $($_.Name) (fuori dalla finestra di $RetainDays giorni)"
                Remove-TreeFast $_.FullName
            }
        }

    # --- Retention per snapshot: restano solo gli ultimi $RetainSnapshots completi ---
    # Agisce dentro la finestra a calendario, quindi anche sugli snapshot di oggi:
    # con 1, la copia del pomeriggio sostituisce quella del mattino. Se la copia
    # ha avuto errori, lo snapshot appena creato e' difettoso e viene eliminato
    # anch'esso: resta solo l'ultima copia completa. Unica eccezione: se su disco
    # non esiste nessuna copia completa, lo snapshot difettoso e $keep restano,
    # perche' una copia parziale e' meglio di nessuna copia.
    if ($RetainSnapshots -lt 1) { $RetainSnapshots = 1 }
    $snaps     = @(Get-Snapshots)
    $latest    = @($snaps | Where-Object { -not $_.Broken } |
                 Sort-Object Rel -Descending | Select-Object -First $RetainSnapshots)
    $keepPaths = @($latest | ForEach-Object { $_.Path })
    if ($code -lt 8 -or $latest.Count -eq 0) { $keepPaths += $SnapDir }
    if ($code -ge 8 -and $latest.Count -eq 0 -and $keep) { $keepPaths += $keep.Path }
    foreach ($s in @($snaps | Where-Object { $keepPaths -notcontains $_.Path })) {
        if ($s.Path -ieq $SnapDir) {
            Write-Host "Retention: elimino lo snapshot difettoso appena creato $($s.Rel)"
            Remove-TreeFast $s.Path
            $scr = '{0} | SCARTATO | {1} | snapshot difettoso eliminato, resta {2} -> vedi {3}' -f `
                   $now.ToString('yyyy-MM-dd HH:mm:ss'), $s.Rel, $latest[0].Rel, $FailReportName
            Add-Content -LiteralPath $HistoryFile -Value $scr -Encoding UTF8
        } else {
            Write-Host "Retention: elimino lo snapshot $($s.Rel) (si conservano gli ultimi $RetainSnapshots)"
            Remove-TreeFast $s.Path
        }
    }

    # --- Rapporto di fallimento: come rilanciare subito -----------------
    # Copia riuscita: il rapporto di un fallimento precedente non serve piu'.
    # Copia con errori: rapporto verboso in _logs, sovrascritto a ogni
    # fallimento, con esito, file non copiati e comandi per rilanciare.
    $FailReport = Join-Path $LogDir $FailReportName
    if ($code -lt 8) {
        if (Test-Path -LiteralPath $FailReport -ErrorAction Stop) {
            Remove-Item -LiteralPath $FailReport -Force -ErrorAction Stop
        }
    } else {
        $codeMeaning = @()
        if ($code -band 16) { $codeMeaning += '16 = errore grave: robocopy si e'' fermato (destinazione non raggiungibile, accesso negato, disco pieno o scollegato).' }
        if ($code -band 8)  { $codeMeaning += '8 = alcuni file o cartelle non sono stati copiati nemmeno al nuovo tentativo (file in uso, permessi, I/O, spazio).' }

        # Errori dal log robocopy: stessa analisi usata per il declassamento, cosi'
        # rapporto e decisione leggono il log nello stesso modo. Se la seconda
        # passata e' stata fatta si legge quella: i suoi errori sono quelli
        # rimasti in piedi dopo un secondo tentativo, cioe' quelli veri.
        $errLog = if ($RetryLog -and (Test-Path -LiteralPath $RetryLog -ErrorAction SilentlyContinue)) { $RetryLog } else { $LogFile }
        $errs = @(Get-RobocopyLogErrors $errLog |
                  ForEach-Object { if ($_.Message) { $_.Text + "`r`n      " + $_.Message } else { $_.Text } })
        $errSummary = Get-RobocopySummary $errLog
        $maxErr = 40

        $drv  = Get-PSDrive -Name $ExpectedDriveLetter -ErrorAction SilentlyContinue
        $free = if ($drv) { '{0:N1} GB' -f ($drv.Free / 1GB) } else { 'non rilevabile' }

        if ($latest.Count -gt 0) {
            $esito = @(
                "Lo snapshot difettoso $rel e' stato ELIMINATO."
                ("Su disco resta solo l'ultima copia completa: " + $latest[0].Rel)
                ('(' + $latest[0].Path + ')')
            )
        } else {
            $esito = @(
                "Su disco NON esiste nessuna copia completa: lo snapshot difettoso $rel"
                "e' stato CONSERVATO (marcato $MarkerName), perche' una copia"
                "parziale e' meglio di nessuna copia. Verra' eliminato al primo backup completo."
            )
        }

        if ($errs.Count) {
            $errLines = @($errs | Select-Object -First $maxErr | ForEach-Object { '  ' + $_ })
            if ($errs.Count -gt $maxErr) { $errLines += "  ... altri $($errs.Count - $maxErr): vedi il log robocopy." }
        } elseif ($errSummary.Found) {
            # Il caso del 2026-10-28: robocopy conta il guasto nel riepilogo e
            # non lo descrive. Dirlo e' meglio che mandare a cercare un codice
            # 16 che non c'era.
            $errLines = @(
                ('  Nessuna riga di errore nel log, ma il riepilogo di robocopy conta {0} directory' -f $errSummary.DirsFailed)
                ('  e {0} file non riusciti, su {1} directory e {2} file esaminati.' -f `
                    $errSummary.FilesFailed, $errSummary.DirsTotal, $errSummary.FilesTotal)
                '  robocopy non dice QUALI: e'' il motivo della seconda passata, che qui non'
                '  e'' bastata. Guarda le ultime righe del log e il registro eventi di sistema'
                '  (dischi in retry, evento disk/153).'
            )
        } else {
            $errLines = @(
                '  Log senza righe di errore e senza riepilogo finale: con codice 16 la copia'
                '  si e'' fermata subito; controlla le ultime righe del log robocopy.'
            )
        }

        $engine = Join-Path $PSScriptRoot 'Backup-Sviluppo.ps1'
        $popup  = Join-Path $PSScriptRoot 'Backup-Conferma.ps1'
        $report = @(
            '================================================================'
            ' BACKUP FALLITO - DA RILANCIARE'
            '================================================================'
            ''
            ('Tentativo:        ' + $now.ToString('yyyy-MM-dd HH:mm:ss'))
            ('Sorgente:         ' + $Source)
            ('Destinazione:     ' + $SnapDir)
            ('Codice robocopy:  ' + $code)
        )
        $report += @($codeMeaning | ForEach-Object { '                  ' + $_ })
        $report += @(
            ('Spazio libero su ' + $ExpectedDriveLetter + ': ' + $free)
            ('Log robocopy:     ' + $LogFile)
        )
        if ($RetryLog) {
            $report += ('Log della ripresa: ' + $RetryLog)
            $report += ('                  seconda passata sullo stesso snapshot, codice robocopy ' + $RetryCode)
        }
        $report += @(
            ''
            '--- ESITO ------------------------------------------------------'
        )
        $report += $esito
        $report += @(
            ''
            ('--- FILE NON COPIATI (errori distinti nel log: {0}) ------------' -f $errs.Count)
        )
        $report += $errLines
        $report += @(
            ''
            '--- COME RILANCIARE SUBITO -------------------------------------'
            '1. Chiudi i programmi che tengono aperti i file elencati sopra'
            '   (IDE, Docker/WSL, database locali, client di sincronizzazione, Outlook).'
            '   Errore 32 = file in uso da un altro processo; 5 = accesso negato;'
            '   112 = spazio insufficiente su disco.'
            '   Errore 2 o 3 = il percorso non esiste piu'' in origine: era effimero ed e'''
            '   stato cancellato mentre la copia era in corso. Se TUTTI gli errori sono di'
            '   questo tipo il backup NON fallisce. Se compare qui vuol dire che accanto a'
            '   compare un secondo errore di natura diversa, o che il percorso e'' ricomparso.'
            ('2. Verifica che ' + $ExpectedDriveLetter + ': sia collegato e abbia spazio libero (ora: ' + $free + ').')
            '3. Rilancia il backup da PowerShell, senza pop-up:'
            ''
            ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + $engine + '"')
            ''
            '   oppure con il pop-up di conferma:'
            ''
            ('     powershell -NoProfile -ExecutionPolicy Bypass -File "' + $popup + '"')
            ''
            "4. Se la nuova copia riesce, sostituisce l'ultima copia completa e"
            '   questo file viene eliminato automaticamente. Se fallisce di nuovo,'
            '   questo file viene riscritto con i nuovi errori.'
        )
        Set-Content -LiteralPath $FailReport -Value $report -Encoding UTF8
        Write-Host ''
        $report | ForEach-Object { Write-Host $_ }
        Write-Host ''
        Write-Host "Rapporto salvato in $FailReport"
    }

    # Pulizia SOLO dei log dettagliati, sulla stessa soglia a calendario delle
    # cartelle-giorno; lo storico (storico-snapshot.txt) NON viene toccato.
    Get-ChildItem -LiteralPath $LogDir -Filter 'backup_*.log' -ErrorAction Stop |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction Stop

    # Cartelle-giorno rimaste vuote dopo le pulizie (mai quella corrente).
    Get-ChildItem -LiteralPath $BackupRoot -Directory -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.FullName -ine $DayDir } |
        ForEach-Object {
            if (@(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction Stop).Count -eq 0) {
                Remove-TreeFast $_.FullName
            }
        }

    if ($code -lt 8) {
        Write-Step "Copia, verifica e pulizia concluse. Puoi richiedere la rimozione sicura del disco."
    } else {
        Write-Step "Backup terminato con errori di copia (codice $code). Consulta il rapporto prima di rilanciare."
    }
}
catch [System.TimeoutException] {
    # Provider impiantato a copia gia' avviata: capita nella verifica che
    # precede la pulizia. Lo snapshot resta marcato incompleto e nessuna
    # cancellazione parte, quindi le copie precedenti restano dove sono.
    $reason = $_.Exception.Message
    Write-Step "BACKUP NON CONCLUSO: $reason"
    Write-LocalBackupError $reason
    exit $EXIT_STORAGE_TIMEOUT
}
catch {
    $reason = $_.Exception.Message
    Write-Step "BACKUP NON CONCLUSO: $reason"
    Write-LocalBackupError $reason
    exit $EXIT_IO_FAILURE
}
finally {
    if ($mutex) {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if ($code -lt 8) { exit $EXIT_OK } else { exit $code }
