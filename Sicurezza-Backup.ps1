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

function Get-PendingCleanup {
    $journal = Get-CleanupJournalPath
    if (Test-Path -LiteralPath $journal -ErrorAction Stop) {
        foreach ($record in @(Get-ChildItem -LiteralPath $journal -File -Force -ErrorAction Stop)) {
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
}

function Update-CleanupJournal([string]$Path, [bool]$Pending) {
    $resolved = Assert-BackupRemovalPath $Path
    $root = Assert-BackupRoot
    $relative = $resolved.Substring($root.Length + 1)
    $entries = @(Get-PendingCleanup)
    $journal = Get-CleanupJournalPath
    $record = Join-Path $journal (($relative -replace '\\', '_') + '.txt')
    if ($Pending) {
        # Un file per operazione: aggiornare un record non riscrive gli altri.
        # Se esiste gia', non si tronca neppure il record dell'operazione ripresa.
        if ($entries -notcontains $relative) {
            New-Item -ItemType Directory -Path $journal -Force -ErrorAction Stop | Out-Null
            Set-Content -LiteralPath $record -Value $relative -Encoding UTF8 -ErrorAction Stop
        }
    } elseif (Test-Path -LiteralPath $record -ErrorAction Stop) {
        Remove-Item -LiteralPath $record -Force -ErrorAction Stop
        if (@(Get-ChildItem -LiteralPath $journal -Force -ErrorAction Stop).Count -eq 0) {
            [IO.Directory]::Delete($journal, $false)
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
