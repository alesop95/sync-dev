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
    'E:\legal-consultant\data',
    # Cloni di repository di terze parti (pokeemerald e simili) tenuti come fonte di
    # consultazione: 49.604 file per appena 0,20 GB di contenuto reale, che su exFAT con
    # cluster da 128 KB diventano 6,13 GB. Il 97% e' spazio sprecato in slack e il
    # contenuto si ricrea con un 'git clone' dall'upstream. Percorso ASSOLUTO per non
    # toccare altre cartelle chiamate 'cloni'. Aggiunto il 2026-10-16.
    'E:\retrogame-mod-pok-dev\_notes\fonti\cloni',
    # Log locali di sync-dev. Da quando il progetto vive su E:\ sta DENTRO la propria
    # sorgente, e l'engine scrive qui (BACKUP-ERRORE.txt) proprio mentre robocopy sta
    # copiando questa cartella: un file che nasce o cambia a copia in corso chiude il
    # backup con ERRORE 2, lo stesso incidente gia' visto con COMMIT-MSG*.txt. Gli
    # script restano inclusi nello snapshot, solo i log no. Aggiunto il 2026-10-16.
    'E:\sync-dev\_logs',
    # Le due parti pesanti e rigenerabili della cache di harmony-book: 5,63 GB in circa
    # 29.400 file. lettura-diretta sono pagine dei PDF rese in webp/png, doc-ingest testi
    # estratti; i PDF d'origine (10-biblioteca\cassaforte-fonti) restano nello snapshot e
    # gli script di tools\ le ricreano. Il resto di 99-cache resta incluso di proposito:
    # lettura-locale\backup tiene copie datate di corpus.sqlite che non si rigenerano.
    # Aggiunto il 2026-10-28: la guardia chiedeva 56,0 GB su 53,8 liberi su J:.
    'E:\harmony-book\_notes\99-cache\lettura-diretta',
    'E:\harmony-book\_notes\99-cache\doc-ingest'
    # '.git'   # NON escludere: verifica del 2026-10-16 su 41 repo di E:\ -> 'my-wedding-day'
    #          # ha 16 commit non pushati e 'serp.systems-full-early_mvp' non ha alcun
    #          # remoto, quindi la sua storia esiste solo qui. Escludere .git li
    #          # perderebbe in silenzio. Costo attuale: 5,00 GB su exFAT per 0,92 GB logici.
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
# Delta zip di harmony-book del 2026-10-15: 5,94 GB che contengono le fonti appena
# entrate in _notes\10-biblioteca\cassaforte-fonti, gia' copiate in originale. Percorso
# ASSOLUTO: gli altri zip di 90-archivio\backup (1,2 GB) sono l'unica storia di _notes,
# che non e' in git, e restano inclusi. Aggiunto il 2026-10-28.
$ExcludeFiles = @('*.tmp','Thumbs.db','.DS_Store','*.vbk','*.vib','*.vbm','COMMIT-MSG*.txt',
    'E:\harmony-book\_notes\90-archivio\backup\harmony-private-delta-20261015T135532Z.zip')

# ===== Guardia sullo spazio libero ==================================
# Il 2026-10-16 il disco e' arrivato a 0 byte liberi durante la copia. Il danno
# non e' stato il backup fallito, ma il blocco che ne e' seguito: con il volume
# saturo l'engine non riusciva piu' a scrivere nemmeno il record da poche
# centinaia di byte del registro delle pulizie, e senza quel record la
# cancellazione che avrebbe liberato spazio non partiva. Disco pieno ->
# pulizia impossibile -> disco pieno: da li' non si esce da soli, e un exFAT
# tenuto a saturazione si corrompe (su J: sono comparse FOUND.000/001/002).
# Questa guardia misura PRIMA di scrivere e, se lo spazio non basta, blocca il
# backup lasciando il disco esattamente com'era.

# Moltiplicatore applicato alla dimensione LOGICA dell'ultimo snapshot riuscito
# (letta dallo storico) per stimare quanto occupera' davvero il prossimo.
# Serve perche' su un file system a cluster grandi l'occupazione reale e' molto
# maggiore di quella logica: il costo non dipende dai byte ma dal NUMERO di file,
# perche' ognuno consuma un cluster intero anche se contiene 80 byte.
#
# Misure su J: (exFAT, cluster 128 KB):
#   2026-10-15  25,55 GB logici -> 47,28 reali = 1,85x  (205.298 file)
#   2026-10-16  26,06 GB logici -> 46,57 reali = 1,79x  (195.524 file)
#   2026-10-16  25,92 GB logici -> 41,93 reali = 1,62x  (157.846 file, cloni esclusi)
#
# Il rapporto scende man mano che si escludono le cartelle a molti file minuscoli,
# perche' e' la media della dimensione dei file a guidarlo. 1.8 copre il caso
# peggiore misurato con un margine, senza bloccare copie che ci starebbero: una
# stima troppo prudente non protegge niente, fa solo saltare il backup. Se si
# cambia l'elenco delle esclusioni conviene ricontrollare questo valore.
# Su una destinazione NTFS con cluster da 4 KB basta 1.15.
$SpaceSafetyFactor = 1.8

# Margine assoluto preteso oltre alla stima, in GB. Copre i log, il registro
# delle pulizie e il fatto che lo snapshot vecchio viene eliminato DOPO la copia.
$MinFreeMarginGB = 5

# Secondi concessi a UNA interrogazione del provider Storage di Windows
# (Get-Volume, Get-Partition, Get-Disk) prima di considerarla persa. Quelle
# chiamate non hanno un timeout proprio, e un disco guasto QUALUNQUE della
# macchina le blocca per sempre: vedi Invoke-StorageQuery in Sicurezza-Backup.ps1.
# Generoso di proposito: su una macchina carica una risposta lenta e' normale,
# un'attesa di tre quarti d'ora no.
$StorageQueryTimeoutSec = 45

# Seconda passata di robocopy quando la prima torna con "alcuni file non
# copiati" (bit 8) ma non con un errore grave (bit 16). Usa gli stessi
# argomenti, quindi /E e mai /MIR: ricopia cio' che manca e non cancella
# niente. Serve ai guasti che robocopy conta e non racconta (2026-10-28: una
# directory non riuscita su 20.945, zero righe di errore nel log) e a quelli
# transitori, dove /R:1 e' una rete troppo larga. Costa un'altra enumerazione
# della sorgente, e solo quando la copia e' gia' andata male.
$RetryCopyOnFailure = $true

# Codici di uscita per comunicare l'esito al chiamante
$EXIT_OK              = 0
$EXIT_DEVICE_MISMATCH = 101    # disco con la lettera attesa ma NON e' il dispositivo atteso
$EXIT_SOURCE_MISSING  = 102    # sorgente non rilevata
$EXIT_DEVICE_MISSING  = 103    # nessun disco con la lettera attesa
$EXIT_VOLUME_UNHEALTHY = 104   # volume degradato o stato non verificabile
$EXIT_IO_FAILURE       = 105   # conteggio, log o pulizia non conclusi
$EXIT_ALREADY_RUNNING  = 106   # backup gia' in corso, nessuna nuova copia
$EXIT_LOW_SPACE        = 107   # spazio libero insufficiente: niente viene scritto
$EXIT_STORAGE_TIMEOUT  = 108   # il provider Storage non risponde: stato dei dischi non verificabile

# ===== Funzioni =====================================================

function Get-DiskForLetter {
    param([string]$Letter)
    # $null significa "nessun disco con quella lettera". Il timeout del provider
    # NON e' quel caso e deve risalire al chiamante: confonderli farebbe dire
    # "disco scollegato" mentre il disco e' li', collegato e sano.
    try {
        return (Invoke-StorageQuery -Description "disco della lettera ${Letter}:" -ArgumentList $Letter -Query {
            param($l)
            Get-Partition -DriveLetter $l -ErrorAction Stop | Get-Disk -ErrorAction Stop
        })
    }
    catch [System.TimeoutException] { throw }
    catch { return $null }
}

function Test-BackupDevice {
    # Verifica che la lettera attesa esista e punti al dispositivo atteso.
    # Ritorna un oggetto: Ok (bool), Status ('OK'|'NODISK'|'MODEL'|'SERIAL'), Reason (string).
    $r = [pscustomobject]@{ Ok = $false; Status = ''; Reason = '' }
    try { $disk = Get-DiskForLetter -Letter $ExpectedDriveLetter }
    catch [System.TimeoutException] {
        $r.Status = 'TIMEOUT'
        $r.Reason = $_.Exception.Message
        return $r
    }
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
