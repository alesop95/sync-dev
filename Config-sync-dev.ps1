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

# Giorni solari di retention
$RetainDays = 5

# Cartelle e file esclusi dalla copia (adatta allo stack)
$ExcludeDirs = @(
    'node_modules', '.pnpm-store', '.pnpm',
    'dist','build','out','.next','.nuxt','.svelte-kit',
    'target',
    '__pycache__','.venv','venv','.tox','.pytest_cache',
    '.cache','.parcel-cache','.turbo','.gradle',
    'coverage'
    # '.git'   # escludi SOLO se ogni repo e' gia' su un remoto
)
$ExcludeFiles = @('*.tmp','Thumbs.db','.DS_Store')

# Codici di uscita per comunicare l'esito al chiamante
$EXIT_OK              = 0
$EXIT_DEVICE_MISMATCH = 101    # disco con la lettera attesa ma NON e' il dispositivo atteso
$EXIT_SOURCE_MISSING  = 102    # sorgente non rilevata
$EXIT_DEVICE_MISSING  = 103    # nessun disco con la lettera attesa

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

# ===== Override locale (non versionato) =============================
# Se esiste config.local.ps1 nella stessa cartella, viene caricato qui e puo'
# sovrascrivere qualsiasi parametro sopra (es. $ExpectedDiskSerial). Il file e'
# escluso dal controllo di versione tramite .gitignore.
$localCfg = Join-Path $PSScriptRoot 'config.local.ps1'
if (Test-Path -LiteralPath $localCfg) { . $localCfg }
