<#
    Backup-Sviluppo.ps1
    Snapshot datati con retention. Parametri e verifiche in Config-sync-dev.ps1.
    Prima di copiare verifica che:
      1) il disco di backup sia ESATTAMENTE quello atteso (modello e, se impostato, serial);
      2) la sorgente sia presente.
    Se una delle due fallisce, NON copia e NON cancella nulla, ed esce con un codice dedicato.
    Cancella SOLO dentro $BackupRoot. La sorgente non viene MAI toccata.
#>

. (Join-Path $PSScriptRoot 'Config-sync-dev.ps1')

# Se la configurazione non si e' caricata (file bloccato o assente), esci con messaggio.
if (-not $BackupRoot) {
    Write-Host "Configurazione non caricata: esegui Unblock-File sui .ps1 della cartella."
    exit 1
}

$LogDir = Join-Path $BackupRoot '_logs'

# Cancellazione robusta anche per alberi profondi (long path safe)
function Remove-TreeFast([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $empty = Join-Path $env:TEMP ('empty_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $empty | Out-Null
    robocopy $empty $path /MIR /NJH /NJS /NP /NFL /NDL /R:1 /W:1 | Out-Null
    Remove-Item -LiteralPath $path  -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
}

# Nome del file sentinella che marca uno snapshot incompleto. Vive dentro la
# cartella dello snapshot, quindi la marcatura sopravvive alla fine dello script:
# e' la memoria che le esecuzioni successive leggono per sapere cosa buttare.
$MarkerName = '_SNAPSHOT-INCOMPLETO.txt'

# Elenco degli snapshot presenti (cartelle AAAA-MM-GG\HH-mm-ss), con il giorno di
# appartenenza e l'indicazione se sono marcati come incompleti.
function Get-Snapshots {
    Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } |
        ForEach-Object {
            $dayName = $_.Name
            Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d{2}-\d{2}-\d{2}$' } |
                ForEach-Object {
                    [pscustomobject]@{
                        Day    = $dayName
                        Date   = [datetime]::ParseExact($dayName, 'yyyy-MM-dd', $null)
                        Rel    = $dayName + '\' + $_.Name
                        Path   = $_.FullName
                        Broken = Test-Path -LiteralPath (Join-Path $_.FullName $MarkerName)
                    }
                }
        }
}

# --- Guardia 1: il disco di backup e' quello atteso? ----------------
$dev = Test-BackupDevice
if (-not $dev.Ok) {
    Write-Host "[$(Get-Date -Format s)] BLOCCATO: $($dev.Reason)"
    if ($dev.Status -eq 'NODISK') { exit $EXIT_DEVICE_MISSING } else { exit $EXIT_DEVICE_MISMATCH }
}

# Da qui il disco e' verificato: possiamo scrivere log su $BackupRoot
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$HistoryFile = Join-Path $LogDir 'storico-snapshot.txt'

# --- Guardia 2: sorgente presente? ----------------------------------
$src = Test-SourceAvailable
if (-not $src.Ok) {
    $blk = '{0} | BLOCCATO | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $src.Reason
    Add-Content -LiteralPath $HistoryFile -Value $blk -Encoding UTF8
    Write-Host "[$(Get-Date -Format s)] BLOCCATO: $($src.Reason)"
    exit $EXIT_SOURCE_MISSING
}

# --- Lock anti-sovrapposizione --------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\BackupSviluppo')
if (-not $mutex.WaitOne(0)) { Write-Host "Backup gia' in corso. Esco."; exit $EXIT_OK }

try {
    $now     = Get-Date
    $DayDir  = Join-Path $BackupRoot $now.ToString('yyyy-MM-dd')
    $SnapDir = Join-Path $DayDir     $now.ToString('HH-mm-ss')
    New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null

    $LogFile = Join-Path $LogDir ("backup_" + $now.ToString('yyyyMMdd_HHmmss') + ".log")

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

    robocopy @RoboArgs
    $code = $LASTEXITCODE

    # robocopy puo' propagare alla destinazione gli attributi della radice sorgente
    # (molte radici di volume sono Nascosto+Sistema), rendendo lo snapshot invisibile
    # in Esplora risorse pur contenendo i dati. Riportiamo le cartelle dello snapshot
    # a "directory normale".
    foreach ($d in @($DayDir, $SnapDir)) {
        $it = Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
        if ($it) { $it.Attributes = [System.IO.FileAttributes]::Directory }
    }

    # --- Storico cumulativo (append, senza retention) ---
    $files  = @(Get-ChildItem -LiteralPath $SnapDir -Recurse -File -Force -ErrorAction SilentlyContinue)
    $count  = $files.Count
    $sizeMB = if ($count) { [math]::Round((($files | Measure-Object -Property Length -Sum).Sum) / 1MB, 1) } else { 0 }
    $rel    = $now.ToString('yyyy-MM-dd') + '\' + $now.ToString('HH-mm-ss')
    $stato  = if ($code -lt 8) { 'OK' } else { "ERRORI (codice $code) -> vedi $(Split-Path $LogFile -Leaf)" }
    $line   = '{0} | {1} | {2} | {3} file | {4} MB' -f `
              $now.ToString('yyyy-MM-dd HH:mm:ss'), $rel, $stato, $count, $sizeMB
    Add-Content -LiteralPath $HistoryFile -Value $line -Encoding UTF8

    # --- Memoria dell'esito: marca lo snapshot incompleto ---------------
    # Codice robocopy >= 8 = la copia e' arrivata in fondo ma alcuni file non
    # sono stati copiati. Lo snapshot resta (meglio parziale che niente) ma viene
    # marcato: le esecuzioni successive sanno che non e' affidabile e lo
    # eliminano appena esiste una copia completa.
    if ($code -ge 8) {
        Set-Content -LiteralPath (Join-Path $SnapDir $MarkerName) -Encoding UTF8 -Value @(
            'SNAPSHOT INCOMPLETO: alcuni file non sono stati copiati.'
            ('Data:            ' + $now.ToString('yyyy-MM-dd HH:mm:ss'))
            ('Codice robocopy: ' + $code)
            ('Log dettagliato: ' + (Split-Path $LogFile -Leaf))
            ''
            "Questo file e' la memoria per le esecuzioni successive: al primo backup"
            'completo lo snapshot marcato viene eliminato automaticamente. Fino a'
            'quel momento la retention conserva anche l ultimo snapshot completo.'
        )
        Write-Host "Snapshot marcato come incompleto (codice $code)."
    }

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
        $keep = $good | Sort-Object Date -Descending | Select-Object -First 1
        $what = 'ultimo snapshot completo'
        if (-not $keep) {
            # Nessuno snapshot completo su disco: si protegge comunque quello
            # precedente, che puo' contenere i file mancati stavolta.
            $keep = $snaps | Where-Object { $_.Path -ine $SnapDir } |
                    Sort-Object Date -Descending | Select-Object -First 1
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
    if ($good.Count -gt 0) {
        foreach ($s in @($snaps | Where-Object { $_.Broken -and $_.Path -ine $SnapDir })) {
            Write-Host "Pulizia: elimino lo snapshot incompleto $($s.Rel)"
            Remove-TreeFast $s.Path
            $pul = '{0} | PULIZIA | {1} | snapshot incompleto eliminato' -f `
                   $now.ToString('yyyy-MM-dd HH:mm:ss'), $s.Rel
            Add-Content -LiteralPath $HistoryFile -Value $pul -Encoding UTF8
        }
    }

    Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } |
        ForEach-Object {
            $d = [datetime]::ParseExact($_.Name, 'yyyy-MM-dd', $null)
            if ($d -lt $cutoff) {
                Write-Host "Retention: elimino il giorno $($_.Name) (fuori dalla finestra di $RetainDays giorni)"
                Remove-TreeFast $_.FullName
            }
        }

    # Pulizia SOLO dei log dettagliati, sulla stessa soglia a calendario delle
    # cartelle-giorno; lo storico (storico-snapshot.txt) NON viene toccato.
    Get-ChildItem -LiteralPath $LogDir -Filter 'backup_*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Cartelle-giorno rimaste vuote dopo le pulizie (mai quella corrente).
    Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.FullName -ine $DayDir } |
        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}
finally {
    $mutex.ReleaseMutex(); $mutex.Dispose()
}

if ($code -lt 8) { exit $EXIT_OK } else { exit $code }
