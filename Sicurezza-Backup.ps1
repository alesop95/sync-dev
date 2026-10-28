<#
    Controlli del volume e pulizia verificata, condivisi dall'engine e dai test.
    Non ripara, formatta o espelle il disco: quelle operazioni restano manuali.
#>

# ===== Interrogazioni al provider Storage ===========================

# Get-Volume, Get-Partition e Get-Disk non hanno un timeout proprio: parlano con
# il provider Storage di Windows, che per rispondere interroga TUTTI i dischi
# della macchina. Basta quindi un solo dispositivo guasto, anche uno che con il
# backup non c'entra niente, perche' il provider resti appeso sui suoi retry e
# la chiamata non torni mai piu'.
#
# 2026-10-23: una chiavetta USB montata su G: smette di rispondere alle 10:02
# (eventi disk/153 a raffica, LBA 0x0, disco 4). Il backup delle 16:50 si ferma
# dentro la guardia sul volume e ci resta 42 minuti: zero CPU, zero I/O, nessun
# log, nessun pop-up, nessuna riga nello storico. Il disco di backup stava
# benissimo e il pop-up di conferma aspettava un engine che non sarebbe mai
# tornato. Da qui in poi ogni interrogazione ha un tetto di tempo: un blocco
# dichiarato, con un codice di uscita e un messaggio, vale sempre piu' di
# un'attesa infinita e muta.

function Get-StorageRetrySuspects {
    # Numeri dei dischi su cui Windows sta ripetendo le operazioni di I/O
    # (evento disk/153) nell'ultima ora. Quando il provider si impianta e'
    # quasi sempre colpa di uno di questi, e dirlo evita di cercare il guasto
    # nel disco di backup, che di solito non ha nulla che non va.
    # Legge solo il registro eventi, mai il provider Storage, e non fallisce
    # mai: e' diagnostica di contorno, non una guardia.
    try {
        $events = @(Get-WinEvent -ErrorAction Stop -MaxEvents 200 -FilterHashtable @{
            LogName = 'System'; ProviderName = 'disk'; Id = 153
            StartTime = (Get-Date).AddHours(-1)
        })
        # Properties[2] e' il numero del disco: si legge dai dati dell'evento,
        # non dal testo, che e' tradotto nella lingua di Windows.
        return @($events |
                 ForEach-Object { [string]$_.Properties[2].Value } |
                 Where-Object { $_ } |
                 Sort-Object -Unique)
    } catch { return @() }
}

function Invoke-StorageQuery {
    # Esegue $Query su un runspace separato e si arrende dopo
    # $StorageQueryTimeoutSec lanciando [System.TimeoutException]. Il tipo
    # dedicato serve ai chiamanti per distinguere "non lo so" da "il disco non
    # c'e'": sono due diagnosi diverse e portano a due codici di uscita diversi.
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Query,
        [object[]]$ArgumentList = @(),
        [string]$Description = 'interrogazione dei dischi'
    )
    $timeout = if ($StorageQueryTimeoutSec -gt 0) { [int]$StorageQueryTimeoutSec } else { 45 }
    $shell = [powershell]::Create()
    $null = $shell.AddScript($Query.ToString())
    foreach ($argument in $ArgumentList) { $null = $shell.AddArgument($argument) }
    $async = $shell.BeginInvoke()
    if (-not $async.AsyncWaitHandle.WaitOne([timespan]::FromSeconds($timeout))) {
        # Il thread resta appeso dentro il provider e non si puo' interrompere:
        # Stop() e Dispose() aspetterebbero proprio la chiamata che non torna,
        # riproducendo lo stallo che si sta evitando. Lo si abbandona: e' un
        # thread di background e non trattiene l'uscita del processo.
        $suspects = @(Get-StorageRetrySuspects)
        $hint = if ($suspects.Count -gt 0) {
            " Windows sta ripetendo le operazioni di I/O sul disco {0} (eventi disk/153 nell'ultima ora): quasi certamente e' quello che tiene bloccato il provider. Scollegalo o ricollegalo, poi rilancia il backup." -f ($suspects -join ', ')
        } else {
            " Nessun disco risulta in retry nell'ultima ora: controlla i dispositivi USB collegati e il registro eventi di sistema."
        }
        throw (New-Object System.TimeoutException (
            ("Il provider Storage di Windows non ha risposto entro $timeout secondi ($Description). " +
             "Non e' detto che il problema sia il disco di backup: un disco guasto QUALUNQUE della macchina blocca queste interrogazioni per tutti." +
             $hint +
             " Copia e pulizia bloccate: non e' stato scritto nulla.")))
    }
    try { return $shell.EndInvoke($async) }
    finally { $shell.Dispose() }
}

function Get-VolumeInfoFromProvider {
    # Implementazione reale, MAI sostituita dai test: e' qui che si parla con il
    # provider, e deve restare verificabile dal vero.
    #
    # La proiezione a stringhe dentro il runspace non e' cosmetica, e' il punto
    # di tutta la funzione. Get-Volume restituisce un CimInstance in cui
    # HealthStatus e OperationalStatus sono numeri: la parola "Healthy" la
    # produce l'adattatore di tipi del modulo Storage, e quell'adattatore vive
    # nel runspace dove il modulo e' caricato. Se l'oggetto attraversa il
    # confine verso un runspace che non lo ha importato, le parole scompaiono e
    # restano i codici grezzi.
    #
    # 2026-10-26: successo davvero. Il primo backup dopo l'introduzione del
    # tetto di tempo si e' bloccato con "Volume J: (16) non sano: 0 / 2", cioe'
    # exFAT / Healthy / OK letti come numeri e confrontati con le stringhe. Il
    # volume era perfetto. L'engine gira come processo nuovo e non chiama mai
    # Get-Volume nel runspace principale, quindi li' l'adattatore non c'e'.
    # Proiettando qui dentro, dove il modulo e' caricato, il chiamante riceve un
    # oggetto semplice con stringhe vere e non dipende piu' da nessun adattatore.
    param([string]$Letter)
    return @(Invoke-StorageQuery -Description "stato del volume ${Letter}:" -ArgumentList $Letter -Query {
        param($l)
        Get-Volume -DriveLetter $l -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                DriveLetter       = [string]$_.DriveLetter
                FileSystemLabel   = [string]$_.FileSystemLabel
                FileSystemType    = [string]$_.FileSystemType
                HealthStatus      = [string]$_.HealthStatus
                OperationalStatus = @($_.OperationalStatus | ForEach-Object { [string]$_ })
                Size              = [long]$_.Size
                SizeRemaining     = [long]$_.SizeRemaining
            }
        }
    })
}

function Get-BackupVolumeInfo {
    # Unico punto da cui le guardie leggono lo stato del volume. I test
    # sostituiscono QUESTO per simulare i volumi senza toccare un disco vero,
    # e lasciano intatta Get-VolumeInfoFromProvider, che resta cosi'
    # verificabile contro il provider reale.
    param([string]$Letter)
    return @(Get-VolumeInfoFromProvider $Letter)
}

# ===== Guardie sul volume ===========================================

function Test-BackupVolume {
    # Status: 'OK' | 'UNHEALTHY' | 'TIMEOUT' | 'UNKNOWN'. Serve al chiamante per
    # scegliere il codice di uscita, perche' "volume da riparare" e "provider
    # che non risponde" chiedono due reazioni diverse all'operatore.
    $result = [pscustomobject]@{ Ok = $false; Status = 'UNKNOWN'; Reason = '' }
    try {
        $volumes = @(Get-BackupVolumeInfo $ExpectedDriveLetter)
        if ($volumes.Count -ne 1) { throw 'Volume non identificabile in modo univoco.' }
        $volume = $volumes[0]
        $health = [string]$volume.HealthStatus
        $operations = @($volume.OperationalStatus | ForEach-Object { [string]$_ })
        if ($health -ne 'Healthy' -or $operations.Count -eq 0 -or
            @($operations | Where-Object { $_ -ne 'OK' }).Count -gt 0) {
            $result.Status = 'UNHEALTHY'
            $result.Reason = "Volume ${ExpectedDriveLetter}: ($($volume.FileSystemType)) non sano: $health / $($operations -join ', '). Copia e pulizia bloccate. Controlla e ripara il volume prima di rilanciare."
            return $result
        }
        $result.Ok = $true
        $result.Status = 'OK'
    } catch [System.TimeoutException] {
        $result.Status = 'TIMEOUT'
        $result.Reason = $_.Exception.Message
    } catch {
        $result.Status = 'UNKNOWN'
        $result.Reason = "Impossibile verificare il volume ${ExpectedDriveLetter}: $($_.Exception.Message) Copia e pulizia bloccate."
    }
    return $result
}

function Get-BackupFreeSpace {
    # Byte liberi sul volume di backup. Funzione a se' stante perche' i test la
    # sostituiscono per simulare un disco pieno senza saturarne uno vero.
    $volumes = @(Get-BackupVolumeInfo $ExpectedDriveLetter)
    if ($volumes.Count -ne 1) { throw 'Volume non identificabile in modo univoco.' }
    return [long]$volumes[0].SizeRemaining
}

function Get-LastSnapshotBytes {
    # Dimensione LOGICA dell'ultimo snapshot riuscito, letta dallo storico.
    # Si preferisce lo storico a una scansione del disco perche' non costa I/O
    # sul volume esterno e segue da se' la crescita della sorgente.
    # 0 = non stimabile (storico assente o senza righe OK).
    $history = Join-Path (Join-Path $BackupRoot '_logs') 'storico-snapshot.txt'
    if (-not (Test-Path -LiteralPath $history -ErrorAction SilentlyContinue)) { return [long]0 }
    $lines = @(Get-Content -LiteralPath $history -Encoding UTF8 -ErrorAction SilentlyContinue |
               Where-Object { $_ -match '\|\s*OK\s*\|' -and $_ -match '([\d.,]+)\s*MB\s*$' })
    if ($lines.Count -eq 0) { return [long]0 }
    if ($lines[-1] -match '([\d.,]+)\s*MB\s*$') {
        # Lo storico e' scritto nella cultura italiana: '.' separa le migliaia,
        # ',' i decimali. Si normalizza prima di convertire.
        $n = ($Matches[1] -replace '\.', '') -replace ',', '.'
        try { return [long]([double]::Parse($n, [Globalization.CultureInfo]::InvariantCulture) * 1MB) }
        catch { return [long]0 }
    }
    return [long]0
}

function Test-BackupFreeSpace {
    # Guardia pre-volo: stima quanto occupera' il prossimo snapshot e lo confronta
    # con lo spazio libero PRIMA che venga scritto un solo byte. Se non basta, il
    # backup si ferma e il disco resta esattamente com'era.
    # Status: 'OK' | 'LOWSPACE' | 'TIMEOUT' | 'UNKNOWN'. Un provider che non
    # risponde non e' un disco pieno: segnalarlo come tale manderebbe
    # l'operatore a liberare spazio su un disco che spazio ne ha.
    $r = [pscustomobject]@{ Ok = $false; Status = 'UNKNOWN'; Reason = ''; FreeBytes = [long]0; NeedBytes = [long]0 }
    try { $r.FreeBytes = Get-BackupFreeSpace }
    catch [System.TimeoutException] {
        $r.Status = 'TIMEOUT'
        $r.Reason = $_.Exception.Message
        return $r
    }
    catch {
        $r.Reason = "Spazio libero su ${ExpectedDriveLetter}: non verificabile: $($_.Exception.Message) Copia bloccata."
        return $r
    }
    $factor = if ($SpaceSafetyFactor -gt 0) { [double]$SpaceSafetyFactor } else { 2.0 }
    $margin = [long](([double]$MinFreeMarginGB) * 1GB)
    $last   = Get-LastSnapshotBytes
    # Senza storico non si puo' stimare lo snapshot: si pretende almeno il margine,
    # cosi' la prima esecuzione non parte comunque su un disco gia' saturo.
    $r.NeedBytes = if ($last -gt 0) { [long]($last * $factor) + $margin } else { $margin }
    if ($r.FreeBytes -lt $r.NeedBytes) {
        $stima = if ($last -gt 0) {
            'stima {0:N1} GB (ultimo snapshot {1:N1} GB x {2}) piu'' {3:N0} GB di margine' -f `
                ($r.NeedBytes/1GB), ($last/1GB), $factor, ([double]$MinFreeMarginGB)
        } else {
            'nessuno storico per stimare lo snapshot: preteso il solo margine di {0:N0} GB' -f ([double]$MinFreeMarginGB)
        }
        $r.Reason = "Spazio insufficiente su ${ExpectedDriveLetter}: liberi {0:N1} GB, servono {1:N1} GB ($stima). Copia BLOCCATA: non e' stato scritto nulla. Libera spazio sul disco di backup, poi rilancia." -f `
                    ($r.FreeBytes/1GB), ($r.NeedBytes/1GB)
        $r.Status = 'LOWSPACE'
        return $r
    }
    $r.Ok = $true
    $r.Status = 'OK'
    return $r
}

function Assert-BackupRoot {
    if ($ExpectedDriveLetter -notmatch '^[A-Za-z]$' -or $BackupRoot -notmatch '^[A-Za-z]:\\') {
        throw 'Lettera o radice di backup non valida: occorre un percorso locale assoluto.'
    }
    $root = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
    $driveRoot = [IO.Path]::GetPathRoot($root).TrimEnd('\')
    if ($driveRoot -ine ($ExpectedDriveLetter + ':') -or $root -ieq $driveRoot) {
        throw 'La radice di backup deve essere una sottocartella del disco atteso.'
    }
    $sourcePath = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    if ($root -ieq $sourcePath -or $root.StartsWith($sourcePath + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $sourcePath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Sorgente e radice di backup si sovrappongono.'
    }
    # Rifiuta anche un collegamento in un antenato della radice.
    $cursor = $root
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor -ErrorAction Stop) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Radice o antenato non sicuro: $cursor"
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $root
}

function Assert-BackupRemovalPath([string]$Path) {
    $root = Assert-BackupRoot
    if ($Path -notmatch '^[A-Za-z]:\\') { throw 'Percorso di pulizia non assoluto.' }
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $prefix = $root + '\'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Pulizia fuori dalla radice di backup: $resolved"
    }
    $relative = $resolved.Substring($prefix.Length)
    if ($relative -notmatch '^\d{4}-\d{2}-\d{2}(\\\d{2}-\d{2}-\d{2})?$') {
        throw "La pulizia ammette solo giorni e snapshot datati: $relative"
    }
    $cursor = $resolved
    while ($cursor -ine $root) {
        if (Test-Path -LiteralPath $cursor -ErrorAction Stop) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Percorso di pulizia non sicuro: $cursor"
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $resolved
}

function Get-CleanupJournalPath {
    $root = Assert-BackupRoot
    $logDir = Join-Path $root '_logs'
    if (Test-Path -LiteralPath $logDir -ErrorAction Stop) {
        $item = Get-Item -LiteralPath $logDir -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'La cartella dei log non e'' una directory sicura.'
        }
    }
    $journal = Join-Path $logDir '_pulizie-pendenti'
    if (Test-Path -LiteralPath $journal -ErrorAction Stop) {
        $item = Get-Item -LiteralPath $journal -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Il registro delle pulizie non e'' una directory sicura.'
        }
    }
    return $journal
}

function Get-LocalCleanupJournalPath {
    # Specchio LOCALE del registro, accanto agli script invece che sul disco di
    # backup. Esiste per un motivo solo: quando la destinazione e' satura non ci
    # entra piu' nemmeno il record da poche centinaia di byte che tiene memoria
    # della cancellazione in corso, e senza quel record la pulizia che
    # libererebbe spazio non parte. Il 2026-10-16 e' finita cosi', con il disco
    # pieno e l'engine incapace di liberarlo. Qui lo spazio c'e' sempre.
    # $LocalJournalBase e' sovrascrivibile dai test per non sporcare il progetto.
    $base = if ($LocalJournalBase) { $LocalJournalBase } else { Join-Path $PSScriptRoot '_logs' }
    return (Join-Path $base '_pulizie-pendenti')
}

function Read-CleanupJournal([string]$Journal) {
    # Legge e convalida i record di un singolo registro. Le regole sono le stesse
    # per quello sul disco di backup e per lo specchio locale.
    if (-not (Test-Path -LiteralPath $Journal -ErrorAction SilentlyContinue)) { return }
    foreach ($record in @(Get-ChildItem -LiteralPath $Journal -File -Force -ErrorAction Stop)) {
        $lines = @(Get-Content -LiteralPath $record.FullName -Encoding UTF8 -ErrorAction Stop)
        if ($lines.Count -ne 1 -or ($record.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Un record della pulizia e'' illeggibile o non valido.'
        }
        $relative = $lines[0].Trim()
        if ($relative -notmatch '^\d{4}-\d{2}-\d{2}(\\\d{2}-\d{2}-\d{2})?$' -or
            $record.Name -ine (($relative -replace '\\', '_') + '.txt')) {
            throw 'Il registro delle pulizie pendenti contiene un percorso non valido.'
        }
        $null = Assert-BackupRemovalPath (Join-Path $BackupRoot $relative)
        $relative
    }
}

function Get-PendingCleanup {
    # Unione dei due registri, senza duplicati: una pulizia e' pendente se
    # risulta tale in almeno uno dei due.
    @(@(Read-CleanupJournal (Get-CleanupJournalPath)) +
      @(Read-CleanupJournal (Get-LocalCleanupJournalPath))) |
        Select-Object -Unique
}

function Update-CleanupJournal([string]$Path, [bool]$Pending) {
    $resolved = Assert-BackupRemovalPath $Path
    $root = Assert-BackupRoot
    $relative = $resolved.Substring($root.Length + 1)
    $entries = @(Get-PendingCleanup)
    $journal = Get-CleanupJournalPath
    $name   = ($relative -replace '\\', '_') + '.txt'
    $record = Join-Path $journal $name
    if ($Pending) {
        # Un file per operazione: aggiornare un record non riscrive gli altri.
        # Se esiste gia', non si tronca neppure il record dell'operazione ripresa.
        if ($entries -notcontains $relative) {
            try {
                New-Item -ItemType Directory -Path $journal -Force -ErrorAction Stop | Out-Null
                Set-Content -LiteralPath $record -Value $relative -Encoding UTF8 -ErrorAction Stop
            } catch {
                # Destinazione piena o non scrivibile: la memoria va in locale, cosi'
                # la cancellazione puo' comunque partire e liberare spazio. Se anche
                # questa fallisce l'eccezione sale, ed e' giusto: senza memoria del
                # residuo non si cancella niente.
                $localJournal = Get-LocalCleanupJournalPath
                New-Item -ItemType Directory -Path $localJournal -Force -ErrorAction Stop | Out-Null
                Set-Content -LiteralPath (Join-Path $localJournal $name) -Value $relative -Encoding UTF8 -ErrorAction Stop
            }
        }
    } else {
        # Chiusura: il record va tolto da ENTRAMBI i registri, perche' non si sa
        # quale dei due lo aveva accolto.
        foreach ($j in @($journal, (Get-LocalCleanupJournalPath))) {
            $r = Join-Path $j $name
            if (Test-Path -LiteralPath $r -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $r -Force -ErrorAction Stop
                if (@(Get-ChildItem -LiteralPath $j -Force -ErrorAction Stop).Count -eq 0) {
                    [IO.Directory]::Delete($j, $false)
                }
            }
        }
    }
}

function Remove-TreeFast([string]$Path) {
    $resolved = Assert-BackupRemovalPath $Path
    if (-not (Test-Path -LiteralPath $resolved -ErrorAction Stop)) {
        Update-CleanupJournal $resolved $false
        return
    }
    $volume = Test-BackupVolume
    if (-not $volume.Ok) { throw $volume.Reason }
    # Fuori dall'albero eliminato: un'interruzione non perde la memoria del residuo.
    Update-CleanupJournal $resolved $true
    $empty = Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('sync-dev-empty-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $empty -ErrorAction Stop | Out-Null
        # Un file aperto da un altro processo (antivirus, indicizzatore) non viene
        # eliminato, ma robocopy NON lo conta come errore: ERRORE 32 nel log e
        # codice 2, cioe' successo. Il 2026-10-26 sono rimasti cosi' due .py in
        # 2026-10-26\11-30-06 e la retention e' caduta su Directory.Delete con un
        # laconico "La directory non e' vuota". Il residuo si verifica quindi a
        # ogni passata e la purga si ripete con attese crescenti: i blocchi di
        # questo tipo durano secondi. Vale uguale per una cartella che resta in
        # piedi perche' qualcuno la tiene aperta.
        # $CleanupRetryDelays e' sovrascrivibile dai test.
        $delays = if ($null -ne $CleanupRetryDelays) { @($CleanupRetryDelays) } else { @(5, 15, 30) }
        $left = @()
        for ($attempt = 0; $attempt -le $delays.Count; $attempt++) {
            if ($attempt -gt 0) {
                Write-Host "Pulizia: $($left.Count) file ancora presenti in $resolved, nuovo tentativo tra $($delays[$attempt - 1]) s"
                Start-Sleep -Seconds $delays[$attempt - 1]
            }
            # /XJ evita di seguire collegamenti. I percorsi sono verificati prima di /MIR.
            robocopy.exe $empty $resolved /MIR /XJ /NJH /NJS /NP /NFL /NDL /R:1 /W:1 | Out-Null
            $cleanupCode = $LASTEXITCODE
            if ($cleanupCode -ge 8) { throw "Pulizia fallita (robocopy $cleanupCode): $resolved" }
            # Si contano file E cartelle: un /MIR che non riesce a togliere una
            # sola cartella lascia zero file e un albero non vuoto, e il
            # Directory.Delete qui sotto non e' ricorsivo. Cercando i soli file
            # quel residuo passava inosservato fino a li', dove ricompariva come
            # un laconico "La directory non e' vuota" che non dice dove.
            $left = @(Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction Stop)
            if ($left.Count -eq 0) { break }
        }
        if ($left.Count -gt 0) {
            $names = @($left | Select-Object -First 5 | ForEach-Object { $_.FullName.Substring($resolved.Length + 1) })
            throw ("Pulizia incompleta di {0}: {1} element{2} non eliminat{2} dopo {3} tentativi, probabilmente in uso da un altro processo (antivirus, indicizzatore, editor aperto sul disco di backup): {4}. " +
                   "La cancellazione resta registrata e riprende al prossimo backup.") -f `
                   $resolved, $left.Count, $(if ($left.Count -eq 1) { 'o' } else { 'i' }), ($delays.Count + 1), ($names -join ', ')
        }
        # Non ricorre sui residui: se /MIR non ha svuotato tutto, fallisce.
        [IO.Directory]::Delete($resolved, $false)
        if (Test-Path -LiteralPath $resolved -ErrorAction Stop) { throw "Residuo ancora presente: $resolved" }
        Update-CleanupJournal $resolved $false
    } finally {
        if (Test-Path -LiteralPath $empty -ErrorAction Stop) {
            [IO.Directory]::Delete($empty, $false)
        }
    }
}

function Get-SnapshotFileStats([string]$Path, [string]$MarkerPath) {
    $stats = [pscustomobject]@{ Count = 0; Bytes = [long]0 }
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction Stop |
        ForEach-Object {
            if ($_.FullName -ine $MarkerPath) {
                $stats.Count++
                $stats.Bytes += $_.Length
            }
        }
    return $stats
}

function Write-LocalBackupError([string]$Reason) {
    # Rimane leggibile anche con il disco esterno assente o danneggiato.
    $localLog = Join-Path $PSScriptRoot '_logs'
    $report = Join-Path $localLog 'BACKUP-ERRORE.txt'
    try {
        New-Item -ItemType Directory -Path $localLog -Force -ErrorAction Stop | Out-Null
        Add-Content -LiteralPath $report -Encoding UTF8 -ErrorAction Stop -Value @(
            ('[{0}] BACKUP BLOCCATO O NON CONCLUSO' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            $Reason
            ''
        )
        Write-Host "Dettaglio salvato in $report"
    } catch { Write-Warning "Impossibile scrivere il rapporto locale: $($_.Exception.Message)" }
}

# ===== Analisi del log di robocopy ==================================

# Errori estratti dal log di robocopy, deduplicati: numero, percorso coinvolto,
# riga ripulita dal timestamp e descrizione (che robocopy scrive sulla riga dopo).
# Il log e' nella code page OEM della console e in italiano dice 'ERRORE' dove
# l'inglese dice 'ERROR'. Un file che fallisce anche al nuovo tentativo compare
# piu' volte.
function Get-RobocopyLogErrors {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return @() }
    $seen = @{}
    Get-Content -LiteralPath $Path -Encoding Oem |
        Select-String -Pattern '\bERRORE?\s+(\d+)\s+\(0x' -Context 0,1 |
        ForEach-Object {
            $text = ($_.Line -replace '^\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+', '').Trim()
            $msg  = if ($_.Context.PostContext) { $_.Context.PostContext[0].Trim() } else { '' }
            $key  = $text + '|' + $msg
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $num  = [int]$_.Matches[0].Groups[1].Value
                $file = if ($text -match '([A-Za-z]:\\.*)$') { $Matches[1].TrimEnd() } else { '' }
                [pscustomobject]@{ Number = $num; Path = $file; Text = $text; Message = $msg }
            }
        }
}

# Numeri della tabella di riepilogo che robocopy stampa in fondo al log: le
# righe Directory e File, di cui interessa soprattutto la quinta colonna, "Non
# riuscita". E' l'unica fonte che dice QUANTE cose sono fallite anche quando
# robocopy non scrive nessuna riga di errore.
#
# 2026-10-28: la copia esce con codice 11, il riepilogo conta 1 directory non
# riuscita su 20.945 e 0 file su 195.088, e nel log non c'e' una sola riga
# ERRORE. Il declassamento, che guarda solo le righe di errore, non trova niente
# da declassare; il rapporto di fallimento annuncia "errori distinti nel log: 0"
# e consiglia di controllare il codice 16, che non era quello. Risultato: 28 GB
# di copia buttati e nessun indizio su che cosa fosse andato storto.
#
# Si legge per posizione e non per etichetta: la tabella e' tradotta nella
# lingua di Windows ('Directory'/'File' in italiano, 'Dirs'/'Files' in inglese),
# ma le sei colonne di interi sono sempre le stesse e solo quelle due righe le
# hanno tutte intere (la riga Byte porta le unita', la riga Durata gli orari).
function Get-RobocopySummary {
    param([string]$Path)
    $summary = [pscustomobject]@{
        Found = $false; DirsTotal = 0; DirsFailed = 0; FilesTotal = 0; FilesFailed = 0
    }
    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return $summary }
    $rows = @(Get-Content -LiteralPath $Path -Encoding Oem |
              Select-String -Pattern '^\s*[^:]+:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$')
    if ($rows.Count -lt 2) { return $summary }
    # Le ultime due righe cosi' fatte sono, in quest'ordine, Directory e File.
    $dirs  = $rows[$rows.Count - 2].Matches[0].Groups
    $files = $rows[$rows.Count - 1].Matches[0].Groups
    $summary.Found       = $true
    $summary.DirsTotal   = [int]$dirs[1].Value
    $summary.DirsFailed  = [int]$dirs[5].Value
    $summary.FilesTotal  = [int]$files[1].Value
    $summary.FilesFailed = [int]$files[5].Value
    return $summary
}

# Un errore e' BENIGNO quando riguarda un elemento che non esiste piu' nemmeno in
# origine: ERRORE 2 (file non trovato) o 3 (percorso non trovato) su un percorso
# dentro la sorgente che adesso risulta assente. E' la firma del file effimero,
# creato e cancellato da un altro processo mentre la copia era in corso: robocopy
# enumera l'albero all'inizio e copia dopo, quindi un file nato e morto nel mezzo
# risulta "non copiato" pur non essendo mai stato da salvare, e lo snapshot resta
# fedele alla sorgente di fine copia.
# Il controllo e' volutamente stretto: percorso DENTRO la sorgente e assente ORA.
# Se il file e' ricomparso, o se il percorso non e' leggibile, non e' benigno.
function Test-VanishedSourceError {
    param($Entry)
    if ($Entry.Number -ne 2 -and $Entry.Number -ne 3) { return $false }
    if (-not $Entry.Path) { return $false }
    try {
        $src = [IO.Path]::GetFullPath($Source).TrimEnd('\') + '\'
        if (-not $Entry.Path.StartsWith($src, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        return -not (Test-Path -LiteralPath $Entry.Path -ErrorAction SilentlyContinue)
    } catch { return $false }
}
