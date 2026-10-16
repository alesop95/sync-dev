<#
    Controlli del volume e pulizia verificata, condivisi dall'engine e dai test.
    Non ripara, formatta o espelle il disco: quelle operazioni restano manuali.
#>

function Test-BackupVolume {
    $result = [pscustomobject]@{ Ok = $false; Reason = '' }
    try {
        $volumes = @(Get-Volume -DriveLetter $ExpectedDriveLetter -ErrorAction Stop)
        if ($volumes.Count -ne 1) { throw 'Volume non identificabile in modo univoco.' }
        $volume = $volumes[0]
        $health = [string]$volume.HealthStatus
        $operations = @($volume.OperationalStatus | ForEach-Object { [string]$_ })
        if ($health -ne 'Healthy' -or $operations.Count -eq 0 -or
            @($operations | Where-Object { $_ -ne 'OK' }).Count -gt 0) {
            $result.Reason = "Volume ${ExpectedDriveLetter}: ($($volume.FileSystemType)) non sano: $health / $($operations -join ', '). Copia e pulizia bloccate. Controlla e ripara il volume prima di rilanciare."
            return $result
        }
        $result.Ok = $true
    } catch {
        $result.Reason = "Impossibile verificare il volume ${ExpectedDriveLetter}: $($_.Exception.Message) Copia e pulizia bloccate."
    }
    return $result
}

function Get-BackupFreeSpace {
    # Byte liberi sul volume di backup. Funzione a se' stante perche' i test la
    # sostituiscono per simulare un disco pieno senza saturarne uno vero.
    $volumes = @(Get-Volume -DriveLetter $ExpectedDriveLetter -ErrorAction Stop)
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
    $r = [pscustomobject]@{ Ok = $false; Reason = ''; FreeBytes = [long]0; NeedBytes = [long]0 }
    try { $r.FreeBytes = Get-BackupFreeSpace }
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
        return $r
    }
    $r.Ok = $true
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
        # /XJ evita di seguire collegamenti. I percorsi sono verificati prima di /MIR.
        robocopy.exe $empty $resolved /MIR /XJ /NJH /NJS /NP /NFL /NDL /R:1 /W:1 | Out-Null
        $cleanupCode = $LASTEXITCODE
        if ($cleanupCode -ge 8) { throw "Pulizia fallita (robocopy $cleanupCode): $resolved" }
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
