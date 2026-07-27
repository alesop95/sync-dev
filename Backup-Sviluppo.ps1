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

    # --- Retention: conserva $RetainDays giorni SOLARI, oggi incluso (solo lato backup) ---
    # Il giorno corrente non va mai eliminato: contiene lo snapshot appena creato.
    if ($RetainDays -lt 1) { $RetainDays = 1 }
    $cutoff = $now.Date.AddDays(-($RetainDays - 1))    # data del giorno piu' vecchio da tenere
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
}
finally {
    $mutex.ReleaseMutex(); $mutex.Dispose()
}

if ($code -lt 8) { exit $EXIT_OK } else { exit $code }
