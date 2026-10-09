<#
    Config-sync-dev.ps1
    Parametri e funzioni condivise. Caricato in dot-source dagli altri script.
    MODIFICA QUI per cambiare sorgente, disco di backup atteso e retention.
#>

# ===== Parametri ====================================================

# Sorgente da copiare (cartella o radice di volume)
$Source      = 'E:\'
$SourceLabel = 'sorgente progetti'      # descrizione usata nei messaggi

# Disco di backup atteso (identita' del dispositivo, non solo la lettera)
$ExpectedDriveLetter = 'J'              # lettera che il disco DEVE avere
$ExpectedDiskModel   = '*Samsung*T7*'   # confronto -like sul nome del disco (FriendlyName)
$ExpectedDiskSerial  = ''               # serial reale in config.local.ps1 (non versionato); '' = non controllato

# Radice degli snapshot sul disco di backup
$BackupRoot = ($ExpectedDriveLetter + ':\backup-sviluppo')

# Giorni solari conservati sul disco di backup, oggi INCLUSO.
# 1 = resta solo la cartella del giorno corrente, quella dello snapshot appena
# creato; tutte le cartelle-giorno precedenti vengono eliminate. Minimo 1.
$RetainDays = 1

# Snapshot completi conservati in totale, i piu' recenti. 1 = dopo ogni copia
# riuscita resta solo lo snapshot appena creato: il backup del pomeriggio
# sostituisce quello del mattino. Minimo 1.
$RetainSnapshots = 1

# Cartelle e file esclusi dalla copia (adatta allo stack)
$ExcludeDirs = @(
    'node_modules', '.pnpm-store', '.pnpm',
    'dist','build','out','.next','.nuxt','.svelte-kit',
    'target',
    '__pycache__','.venv','venv','.tox','.pytest_cache',
    '.cache','.parcel-cache','.turbo','.gradle',
    'coverage',
    # Corpus statico ~288k file (.md) / ~4 GB: troppo pesante per snapshot completi
    # ripetuti (faceva sforare il limite di 3 ore del task). Percorso ASSOLUTO cosi'
    # esclude SOLO questo, non altre cartelle chiamate 'data'. Va salvato a parte.
    'E:\legal-consultant\data'
    # '.git'   # escludi SOLO se ogni repo e' gia' su un remoto
)
# Backup di macchina Veeam Agent (full .vbk, incrementale .vib, metadati .vbm, secondo
# la guida "Types of Backup Files" di Veeam Agent for Linux): un punto di ripristino e'
# di decine di GB e non cambia, quindi ricopiarlo ogni giorno su J: duplicherebbe una copia
# statica e consumerebbe l'SSD. Esclusi per estensione, a ogni profondita', finche' i backup
# non avranno una destinazione propria sul NAS. Aggiunto il 2026-09-30, PA-013 del progetto
# diy-2way-monitors-home (MS-169).
# Messaggi di commit temporanei (_notes\COMMIT-MSG.txt e varianti): l'agente li scrive,
# l'utente li consuma nel commit e li cancella, a volte proprio mentre robocopy sta
# copiando, e il file sparito chiudeva il backup con ERRORE 2. Il contenuto finisce
# comunque nella history git. Il suffisso .txt tiene fuori gli hook git 'commit-msg'
# (senza estensione), che vanno salvati. Aggiunto il 2026-10-05.
$ExcludeFiles = @('*.tmp','Thumbs.db','.DS_Store','*.vbk','*.vib','*.vbm','COMMIT-MSG*.txt')

# Codici di uscita per comunicare l'esito al chiamante
$EXIT_OK              = 0
$EXIT_DEVICE_MISMATCH = 101    # disco con la lettera attesa ma NON e' il dispositivo atteso
$EXIT_SOURCE_MISSING  = 102    # sorgente non rilevata
$EXIT_DEVICE_MISSING  = 103    # nessun disco con la lettera attesa
$EXIT_VOLUME_UNHEALTHY = 104   # volume degradato o stato non verificabile
$EXIT_IO_FAILURE       = 105   # conteggio, log o pulizia non conclusi
$EXIT_ALREADY_RUNNING  = 106   # backup gia' in corso, nessuna nuova copia

# ===== Funzioni =====================================================

function Get-DiskForLetter {
    param([string]$Letter)
    try {
        $p = Get-Partition -DriveLetter $Letter -ErrorAction Stop
        return ($p | Get-Disk -ErrorAction Stop)
    } catch { return $null }
}

function Test-BackupDevice {
    # Verifica che la lettera attesa esista e punti al dispositivo atteso.
    # Ritorna un oggetto: Ok (bool), Status ('OK'|'NODISK'|'MODEL'|'SERIAL'), Reason (string).
    $r = [pscustomobject]@{ Ok = $false; Status = ''; Reason = '' }
    $disk = Get-DiskForLetter -Letter $ExpectedDriveLetter
    if (-not $disk) {
        $r.Status = 'NODISK'
        $r.Reason = "Nessun disco con lettera ${ExpectedDriveLetter}: collegato."
        return $r
    }
    if ($ExpectedDiskModel -and ($disk.FriendlyName -notlike $ExpectedDiskModel)) {
        $r.Status = 'MODEL'
        $r.Reason = "Il disco ${ExpectedDriveLetter}: e' '$($disk.FriendlyName)', atteso un modello '$ExpectedDiskModel'."
        return $r
    }
    if ($ExpectedDiskSerial -and ((("$($disk.SerialNumber)").Trim()) -ne $ExpectedDiskSerial.Trim())) {
        $r.Status = 'SERIAL'
        $r.Reason = "Numero di serie del disco ${ExpectedDriveLetter}: non corrispondente a quello atteso."
        return $r
    }
    $r.Ok = $true
    $r.Status = 'OK'
    return $r
}

function Test-SourceAvailable {
    # Verifica che la sorgente sia presente.
    $r = [pscustomobject]@{ Ok = $false; Reason = '' }
    if (Test-Path -LiteralPath $Source) {
        $r.Ok = $true
    } else {
        $r.Reason = "La $SourceLabel al percorso '$Source' non e' rilevata. Imposta un'altra sorgente modificando la variabile in Config-sync-dev.ps1."
    }
    return $r
}

# Controlli del volume e pulizia verificata, senza riparazioni automatiche.
. (Join-Path $PSScriptRoot 'Sicurezza-Backup.ps1')

# ===== Override locale (non versionato) =============================
# Se esiste config.local.ps1 nella stessa cartella, viene caricato qui e puo'
# sovrascrivere qualsiasi parametro sopra (es. $ExpectedDiskSerial). Il file e'
# escluso dal controllo di versione tramite .gitignore.
$localCfg = Join-Path $PSScriptRoot 'config.local.ps1'
if (Test-Path -LiteralPath $localCfg) { . $localCfg }
