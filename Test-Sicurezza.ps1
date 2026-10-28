<#
    Regressioni del backup con volumi simulati e file temporanei isolati.
    Non legge o modifica la sorgente reale, J: o i task pianificati.
    Eseguire: powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Sicurezza.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Sicurezza-Backup.ps1')
$testRoot = Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('sync-dev-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$ExpectedDriveLetter = [IO.Path]::GetPathRoot($testRoot).Substring(0, 1)
$Source = Join-Path $testRoot 'source'
$BackupRoot = Join-Path $testRoot 'backups'
New-Item -ItemType Directory -Path $Source, $BackupRoot | Out-Null
$passed = 0

function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "TEST FALLITO: $Name" }
    $script:passed++
    Write-Host "OK: $Name"
}
function Assert-Throws([scriptblock]$Action, [string]$Name) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert-True $thrown $Name
}
function Assert-ThrowsTimeout([scriptblock]$Action, [string]$Name) {
    # Il TIPO dell'eccezione e' il contratto fra Invoke-StorageQuery e le
    # guardie: se degrada a eccezione generica, il backup torna a segnalare
    # "disco assente" o "disco pieno" al posto di "provider non raggiungibile".
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception }
    Assert-True ($caught -is [System.TimeoutException]) $Name
}
function Get-BackupVolumeInfo {
    [CmdletBinding()] param([string]$Letter)
    if ($script:volumeTimeout) { throw (New-Object System.TimeoutException 'Provider simulato: nessuna risposta') }
    if ($script:volumeThrows) { throw 'Query volume non disponibile' }
    return $script:mockVolumes
}
$mockVolumes = @([pscustomobject]@{ HealthStatus = 'Healthy'; OperationalStatus = @('OK'); FileSystemType = 'exFAT' })
$volumeThrows = $false
$volumeTimeout = $false

try {
    Assert-True (Test-BackupVolume).Ok 'Volume sano accettato'
    $mockVolumes[0].HealthStatus = 'Warning'
    $mockVolumes[0].OperationalStatus = @('Full Repair Needed')
    Assert-True (-not (Test-BackupVolume).Ok) 'Volume da riparare bloccato'
    $mockVolumes[0].HealthStatus = 'Healthy'
    Assert-True (-not (Test-BackupVolume).Ok) 'Stato operativo degradato bloccato anche con HealthStatus Healthy'
    $mockVolumes = @()
    Assert-True (-not (Test-BackupVolume).Ok) 'Volume assente bloccato'
    $volumeThrows = $true
    Assert-True (-not (Test-BackupVolume).Ok) 'Errore della query bloccato'
    $volumeThrows = $false
    $mockVolumes = @([pscustomobject]@{ HealthStatus = 'Healthy'; OperationalStatus = @('OK'); FileSystemType = 'exFAT' })

    # --- Tetto di tempo sulle interrogazioni dei dischi (2026-10-23) ---
    # Senza questo, un disco guasto qualunque della macchina ferma il backup
    # per sempre dentro una guardia, senza log ne' pop-up: e' successo davvero.
    $StorageQueryTimeoutSec = 2
    Assert-True ((Invoke-StorageQuery -Query { param($x) $x * 2 } -ArgumentList 21) -eq 42) `
        'Query ai dischi: il valore torna al chiamante'
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    Assert-ThrowsTimeout { Invoke-StorageQuery -Query { Start-Sleep -Seconds 60 } -Description 'prova' } `
        'Query ai dischi che non torna: TimeoutException invece di attesa infinita'
    $elapsed.Stop()
    Assert-True ($elapsed.Elapsed.TotalSeconds -lt 30) `
        'Query ai dischi che non torna: si molla al timeout, non si aspetta la fine'
    Assert-True (@(Get-StorageRetrySuspects) -isnot [System.Exception]) `
        'Diagnostica dei dischi in retry: non fallisce mai'

    $volumeTimeout = $true
    $timedOut = Test-BackupVolume
    Assert-True (-not $timedOut.Ok -and $timedOut.Status -eq 'TIMEOUT') `
        'Provider che non risponde: volume bloccato con stato TIMEOUT, non UNKNOWN'
    $timedOutSpace = Test-BackupFreeSpace
    Assert-True (-not $timedOutSpace.Ok -and $timedOutSpace.Status -eq 'TIMEOUT') `
        'Provider che non risponde: spazio bloccato con stato TIMEOUT, non disco pieno'
    # Su un percorso inesistente Remove-TreeFast esce prima di interrogare il
    # volume: per verificare la guardia serve una cartella che esiste davvero.
    $daSalvare = Join-Path $BackupRoot '2026-01-01\09-00-00'
    New-Item -ItemType Directory -Path $daSalvare -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $daSalvare 'dentro.txt') -Value 'non si tocca'
    Assert-Throws { Remove-TreeFast $daSalvare } `
        'Provider che non risponde: nessuna cancellazione parte'
    Assert-True (Test-Path -LiteralPath (Join-Path $daSalvare 'dentro.txt')) `
        'Provider che non risponde: lo snapshot resta intatto'
    $volumeTimeout = $false
    $StorageQueryTimeoutSec = 45

    # --- Contro il provider VERO, non contro uno stub (2026-10-26) ---
    # Gli stub qui sopra restituiscono stringhe e non potevano accorgersi che il
    # percorso reale ne restituiva di numeriche: il primo backup col tetto di
    # tempo si e' bloccato su un volume sano letto come "0 / 2". Questa verifica
    # attraversa Invoke-StorageQuery e il provider per davvero, in sola lettura,
    # sulla lettera del disco temporaneo di test.
    $reale = @(Get-VolumeInfoFromProvider $ExpectedDriveLetter)
    Assert-True ($reale.Count -eq 1) 'Provider reale: un solo volume per la lettera di test'
    Assert-True ($reale[0].HealthStatus -notmatch '^\d+$') `
        'Provider reale: HealthStatus e'' una parola, non il codice numerico CIM'
    Assert-True (@($reale[0].OperationalStatus | Where-Object { $_ -match '^\d+$' }).Count -eq 0) `
        'Provider reale: OperationalStatus e'' una parola, non il codice numerico CIM'
    Assert-True ($reale[0].FileSystemType -notmatch '^\d+$') `
        'Provider reale: FileSystemType e'' una parola, non il codice numerico CIM'
    Assert-True ($reale[0].SizeRemaining -gt 0) 'Provider reale: spazio libero letto come numero'

    Assert-Throws { Remove-TreeFast $BackupRoot } 'Radice del backup protetta'
    Assert-Throws { Remove-TreeFast $Source } 'Sorgente protetta'
    Assert-Throws { Remove-TreeFast (Join-Path $BackupRoot '..\source') } 'Traversal fuori dalla radice bloccato'
    Assert-Throws { Remove-TreeFast (Join-Path $BackupRoot '_logs') } 'Log protetti dalla pulizia degli snapshot'
    $originalRoot = $BackupRoot
    $BackupRoot = [IO.Path]::GetPathRoot($testRoot)
    Assert-Throws { Assert-BackupRoot } 'Radice del volume vietata'
    $BackupRoot = $Source
    Assert-Throws { Assert-BackupRoot } 'Sovrapposizione con la sorgente vietata'
    $BackupRoot = $originalRoot

    $safeSnapshot = Join-Path $BackupRoot '2026-01-01\08-00-00'
    $longPath = $safeSnapshot
    foreach ($index in 1..7) { $longPath = Join-Path $longPath ('cartella-' + $index + '-' + ('x' * 40)) }
    [IO.Directory]::CreateDirectory('\\?\' + $longPath) | Out-Null
    [IO.File]::WriteAllText('\\?\' + (Join-Path $longPath 'file.txt'), 'test')
    Remove-TreeFast $safeSnapshot
    Assert-True (-not (Test-Path -LiteralPath $safeSnapshot)) 'Pulizia reale di un albero con percorsi oltre 260 caratteri'
    Assert-True (@(Get-PendingCleanup).Count -eq 0) 'Registro svuotato dopo una cancellazione riuscita'

    $protected = Join-Path $testRoot 'protected'
    New-Item -ItemType Directory -Path $protected | Out-Null
    Set-Content -LiteralPath (Join-Path $protected 'keep.txt') -Value 'conservare'
    $junction = Join-Path $BackupRoot '2026-01-02\08-00-00'
    New-Item -ItemType Directory -Path (Split-Path $junction -Parent) | Out-Null
    New-Item -ItemType Junction -Path $junction -Target $protected | Out-Null
    try {
        Assert-Throws { Remove-TreeFast $junction } 'Snapshot che punta fuori dalla radice bloccato'
        Assert-True (Test-Path -LiteralPath (Join-Path $protected 'keep.txt')) 'Destinazione del collegamento preservata'
    } finally { [IO.Directory]::Delete($junction, $false) }

    $failedSnapshot = Join-Path $BackupRoot '2026-01-03\08-00-00'
    New-Item -ItemType Directory -Path $failedSnapshot | Out-Null
    Set-Content -LiteralPath (Join-Path $failedSnapshot 'keep.txt') -Value 'residuo'
    function robocopy.exe { $global:LASTEXITCODE = 8 }
    try {
        Assert-Throws { Remove-TreeFast $failedSnapshot } 'Errore di cancellazione propagato'
        Assert-True (@(Get-PendingCleanup) -contains '2026-01-03\08-00-00') 'Residuo registrato per il recupero successivo'
        Assert-True (Test-Path -LiteralPath (Join-Path $failedSnapshot 'keep.txt')) 'Cancellazione fallita non dichiarata riuscita'
    } finally { Remove-Item -LiteralPath 'Function:\robocopy.exe' }
    Remove-TreeFast $failedSnapshot
    Assert-True (@(Get-PendingCleanup).Count -eq 0) 'Pulizia pendente ripresa e verificata'

    # Un file in uso non viene eliminato ma robocopy esce con 2 (successo): il
    # residuo va riconosciuto e la purga ripetuta (caso del 2026-10-26).
    $CleanupRetryDelays = @(0, 0)
    $lockedSnapshot = Join-Path $BackupRoot '2026-01-04\08-00-00'
    New-Item -ItemType Directory -Path (Join-Path $lockedSnapshot 'sub') | Out-Null
    Set-Content -LiteralPath (Join-Path $lockedSnapshot 'sub\bloccato.py') -Value 'in uso'
    $script:roboCalls = 0
    $realRobocopy = (Get-Command robocopy.exe -CommandType Application).Source
    function robocopy.exe {
        $script:roboCalls++
        if ($script:roboCalls -eq 1) { $global:LASTEXITCODE = 2; return }
        & $realRobocopy @args
    }
    try {
        Remove-TreeFast $lockedSnapshot
        Assert-True (-not (Test-Path -LiteralPath $lockedSnapshot)) 'Blocco transitorio: residuo eliminato al tentativo successivo'
        Assert-True ($script:roboCalls -eq 2) 'Blocco transitorio: purga ripetuta una sola volta'
        Assert-True (@(Get-PendingCleanup).Count -eq 0) 'Blocco transitorio: registro chiuso'
    } finally { Remove-Item -LiteralPath 'Function:\robocopy.exe' }

    New-Item -ItemType Directory -Path (Join-Path $lockedSnapshot 'sub') | Out-Null
    $lockedFile = Join-Path $lockedSnapshot 'sub\bloccato.py'
    Set-Content -LiteralPath $lockedFile -Value 'in uso'
    $handle = [IO.File]::Open($lockedFile, 'Open', 'Read', 'Read')
    try {
        $message = ''
        try { Remove-TreeFast $lockedSnapshot } catch { $message = $_.Exception.Message }
        Assert-True ($message -like '*Pulizia incompleta*bloccato.py*') 'Blocco persistente: errore esplicito con il file rimasto'
        Assert-True (@(Get-PendingCleanup) -contains '2026-01-04\08-00-00') 'Blocco persistente: residuo registrato per il recupero'
    } finally { $handle.Close() }
    Remove-TreeFast $lockedSnapshot
    Assert-True (@(Get-PendingCleanup).Count -eq 0) 'Blocco rilasciato: pulizia ripresa e verificata'

    # Una cartella che resta in piedi senza nessun file dentro: /MIR esce con 2,
    # il controllo che guardava i soli file non vedeva niente e il
    # Directory.Delete non ricorsivo falliva con "La directory non e' vuota",
    # senza dire quale cartella fosse.
    $dirSnapshot = Join-Path $BackupRoot '2026-01-05\08-00-00'
    New-Item -ItemType Directory -Path (Join-Path $dirSnapshot 'resta') | Out-Null
    function robocopy.exe {
        param([Parameter(ValueFromRemainingArguments=$true)][object[]]$RoboArgs)
        # Svuota i file e lascia in piedi le cartelle, come robocopy quando non
        # riesce a rimuoverne una: codice 2, cioe' successo.
        @(Get-ChildItem -LiteralPath $RoboArgs[1] -Recurse -File -Force) | Remove-Item -Force
        $global:LASTEXITCODE = 2
    }
    try {
        $message = ''
        try { Remove-TreeFast $dirSnapshot } catch { $message = $_.Exception.Message }
        Assert-True ($message -like '*Pulizia incompleta*resta*') 'Cartella rimasta senza file: residuo nominato, non "La directory non e'' vuota"'
        Assert-True (@(Get-PendingCleanup) -contains '2026-01-05\08-00-00') 'Cartella rimasta: residuo registrato per il recupero'
    } finally { Remove-Item -LiteralPath 'Function:\robocopy.exe' }
    Remove-TreeFast $dirSnapshot
    Assert-True (@(Get-PendingCleanup).Count -eq 0) 'Cartella rimasta: pulizia ripresa e verificata'
    $CleanupRetryDelays = $null

    # ===== Guardia sullo spazio libero ==============================
    # Lo storico e' scritto nella cultura italiana: '.' per le migliaia, ','
    # per i decimali. Una lettura sbagliata qui falserebbe la stima.
    $logDirTest = Join-Path $BackupRoot '_logs'
    New-Item -ItemType Directory -Path $logDirTest -Force | Out-Null
    $historyTest = Join-Path $logDirTest 'storico-snapshot.txt'
    Assert-True ((Get-LastSnapshotBytes) -eq 0) 'Storico assente: snapshot non stimabile'
    Set-Content -LiteralPath $historyTest -Encoding UTF8 -Value @(
        '2026-10-15 12:31:10 | 2026-10-15\12-31-10 | OK | 204241 file | 13749,1 MB'
        '2026-10-15 17:00:10 | 2026-10-15\17-00-10 | OK | 205298 file | 26168,3 MB'
        '2026-10-16 12:30:06 | 2026-10-16\12-30-06 | ERRORI (codice 11) -> vedi x.log | 195523 file | 26688,9 MB'
    )
    $lastBytes = Get-LastSnapshotBytes
    Assert-True ([math]::Abs($lastBytes - (26168.3 * 1MB)) -lt 1MB) 'Ultimo snapshot OK letto dallo storico, decimali italiani comp' + 'resi'
    Assert-True ($lastBytes -lt (26688.9 * 1MB)) 'Le righe con ERRORI non vengono usate per la stima'

    $SpaceSafetyFactor = 2.0
    $MinFreeMarginGB   = 5
    $script:freeBytes  = [long](60 * 1GB)
    $script:freeThrows = $false
    function Get-BackupFreeSpace {
        if ($script:freeThrows) { throw 'Volume non interrogabile' }
        return $script:freeBytes
    }
    # Servono 26168,3 MB x 2 + 5 GB = circa 56,1 GB.
    Assert-True (Test-BackupFreeSpace).Ok 'Spazio sufficiente: copia ammessa'
    $script:freeBytes = [long](50 * 1GB)
    $lowSpace = Test-BackupFreeSpace
    Assert-True (-not $lowSpace.Ok) 'Spazio insufficiente: copia bloccata'
    Assert-True ($lowSpace.NeedBytes -gt $lowSpace.FreeBytes) 'Il blocco riporta quanto serve e quanto c''e'''
    $script:freeBytes = [long]0
    Assert-True (-not (Test-BackupFreeSpace).Ok) 'Disco a zero byte: copia bloccata prima di scrivere'
    $script:freeThrows = $true
    Assert-True (-not (Test-BackupFreeSpace).Ok) 'Spazio non verificabile: copia bloccata'
    $script:freeThrows = $false
    Remove-Item -LiteralPath 'Function:\Get-BackupFreeSpace'
    Remove-Item -LiteralPath $historyTest -Force

    # ===== Registro delle pulizie con destinazione satura ===========
    # Il 2026-10-16 il disco pieno impediva di scrivere il record del registro,
    # e senza record la cancellazione che avrebbe liberato spazio non partiva.
    # Lo specchio locale esiste per rompere quello stallo.
    $LocalJournalBase = Join-Path $testRoot 'giornale-locale'
    $fullDiskSnapshot = Join-Path $BackupRoot '2026-02-01\09-00-00'
    New-Item -ItemType Directory -Path $fullDiskSnapshot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fullDiskSnapshot 'dati.txt') -Value 'da eliminare'
    $script:failDestWrites = $true
    function Set-Content {
        param([string]$LiteralPath, $Value, $Encoding, $ErrorAction)
        if ($script:failDestWrites -and $LiteralPath.StartsWith($BackupRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Spazio su disco insufficiente.'
        }
        Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value -Encoding UTF8
    }
    try {
        Update-CleanupJournal $fullDiskSnapshot $true
        Assert-True (@(Get-PendingCleanup) -contains '2026-02-01\09-00-00') 'Destinazione satura: la pulizia resta memorizzata nello specchio locale'
        Assert-True (Test-Path -LiteralPath (Join-Path (Get-LocalCleanupJournalPath) '2026-02-01_09-00-00.txt')) 'Record scritto nel registro locale'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path (Get-CleanupJournalPath) '2026-02-01_09-00-00.txt'))) 'Nessun record sulla destinazione satura'
    } finally {
        $script:failDestWrites = $false
        Remove-Item -LiteralPath 'Function:\Set-Content'
    }
    Remove-TreeFast $fullDiskSnapshot
    Assert-True (-not (Test-Path -LiteralPath $fullDiskSnapshot)) 'Pulizia eseguita malgrado il registro fosse finito in locale'
    Assert-True (@(Get-PendingCleanup).Count -eq 0) 'Chiusura della pulizia ripulisce anche lo specchio locale'
    $LocalJournalBase = $null

    # Esegue l'engine vero in processi separati: i mock stanno solo nella copia
    # temporanea della configurazione locale, mai nel progetto installato.
    function New-EngineFixture([string]$Name, [bool]$Residues) {
        $fixture = Join-Path $testRoot $Name
        New-Item -ItemType Directory -Path $fixture | Out-Null
        foreach ($file in @('Config-sync-dev.ps1', 'Sicurezza-Backup.ps1', 'Backup-Sviluppo.ps1')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $fixture
        }
        $src = Join-Path $fixture 'source'
        $backups = Join-Path $fixture 'backups'
        $previousDay = (Get-Date).Date.AddDays(-1).ToString('yyyy-MM-dd')
        $previous = Join-Path $backups ($previousDay + '\08-00-00')
        New-Item -ItemType Directory -Path $src, $previous, (Join-Path $backups '_logs'), (Join-Path $backups 'unrelated') | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'file.txt') -Value 'nuova copia'
        Set-Content -LiteralPath (Join-Path $previous 'previous.txt') -Value 'ultima copia completa'
        Set-Content -LiteralPath (Join-Path $backups 'unrelated\keep.txt') -Value 'fuori dalla pulizia'
        if ($Residues) {
            $broken = Join-Path $backups ((Get-Date).Date.AddDays(-2).ToString('yyyy-MM-dd') + '\08-00-00')
            $pendingRel = (Get-Date).Date.AddDays(-3).ToString('yyyy-MM-dd') + '\08-00-00'
            $pending = Join-Path $backups $pendingRel
            $empty = Join-Path $backups (Get-Date).Date.AddDays(-4).ToString('yyyy-MM-dd')
            New-Item -ItemType Directory -Path $broken, $pending, $empty | Out-Null
            Set-Content -LiteralPath (Join-Path $broken '_SNAPSHOT-INCOMPLETO.txt') -Value 'incompleto'
            Set-Content -LiteralPath (Join-Path $pending 'residuo.txt') -Value 'cancellazione interrotta'
            New-Item -ItemType Directory -Path (Join-Path $backups '_logs\_pulizie-pendenti') | Out-Null
            Set-Content -LiteralPath (Join-Path (Join-Path $backups '_logs\_pulizie-pendenti') (($pendingRel -replace '\\', '_') + '.txt')) -Value $pendingRel
        }
        return [pscustomobject]@{ Path = $fixture; Backups = $backups; Previous = $previous; Source = $src }
    }

    function Invoke-EngineFixture($Fixture, [string]$Scenario) {
        $configuration = @'
$Source = Join-Path $PSScriptRoot 'source'
$SourceLabel = 'sorgente temporanea di test'
$BackupRoot = Join-Path $PSScriptRoot 'backups'
$ExpectedDriveLetter = [IO.Path]::GetPathRoot($BackupRoot).Substring(0, 1)
$script:scenario = '__SCENARIO__'
$script:copyCalled = $false
$script:roboPass = 0
function Test-BackupDevice { [pscustomobject]@{ Ok = $true; Status = 'OK'; Reason = '' } }
function Get-BackupVolumeInfo {
    [CmdletBinding()] param([string]$Letter)
    $bad = $script:scenario -eq 'unhealthy' -or ($script:scenario -eq 'degraded-after-copy' -and $script:copyCalled)
    [pscustomobject]@{
        HealthStatus = $(if ($bad) { 'Warning' } else { 'Healthy' })
        OperationalStatus = @($(if ($bad) { 'Full Repair Needed' } else { 'OK' }))
        FileSystemType = 'exFAT'
        # Lo scenario 'low-space' simula il disco saturo del 2026-10-16.
        SizeRemaining = $(if ($script:scenario -eq 'low-space') { [long]0 } else { [long](500 * 1GB) })
    }
}
function robocopy {
    param([Parameter(ValueFromRemainingArguments=$true)][object[]]$RoboArgs)
    $script:copyCalled = $true
    if ($script:scenario -eq 'copy-failure') { $global:LASTEXITCODE = 8; return }
    # 'silent-failure' riproduce il 2026-10-28: prima passata con codice 11 e
    # una directory non riuscita nel riepilogo, zero righe di errore nel log;
    # seconda passata pulita. Il tutto copiando regolarmente il file.
    if ($script:scenario -eq 'silent-failure') {
        $script:roboPass++
        $log = @($RoboArgs | Where-Object { "$_".StartsWith('/LOG:') })[0].Substring(5)
        Set-Content -LiteralPath $log -Encoding Oem -Value @(
            '              Totale   Copiato  IgnorateNon corrispondentiNon riuscitaSupplementari'
            ('Directory:        12        11         0         0         ' + $(if ($script:roboPass -eq 1) { '1' } else { '0' }) + '         0')
            '     File:       100       100         0         0         0         1'
            '     Byte:  1.0 m  1.0 m         0         0         0       300')
        if ($script:roboPass -eq 1) {
            Copy-Item -LiteralPath (Join-Path $RoboArgs[0] 'file.txt') -Destination $RoboArgs[1]
            $global:LASTEXITCODE = 11
        } else {
            $global:LASTEXITCODE = 1
        }
        return
    }
    Copy-Item -LiteralPath (Join-Path $RoboArgs[0] 'file.txt') -Destination $RoboArgs[1]
    $global:LASTEXITCODE = 1
}
if ($script:scenario -eq 'cleanup-failure') {
    function robocopy.exe { $global:LASTEXITCODE = 8 }
}
if ($script:scenario -eq 'stats-failure') {
    function Get-ChildItem {
        [CmdletBinding()] param([string]$LiteralPath, [switch]$Directory, [switch]$File, [switch]$Recurse, [switch]$Force, [string]$Filter)
        if ($Recurse -and $LiteralPath.StartsWith($BackupRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Errore simulato: directory danneggiata e illeggibile'
        }
        Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
    }
}
'@
        Set-Content -LiteralPath (Join-Path $Fixture.Path 'config.local.ps1') -Encoding UTF8 -Value ($configuration.Replace('__SCENARIO__', $Scenario))
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Fixture.Path 'Backup-Sviluppo.ps1') 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { Write-Host ($output -join "`n") }
        return $exitCode
    }

    $fixture = New-EngineFixture 'healthy' $true
    Assert-True ((Invoke-EngineFixture $fixture 'healthy') -eq 0) 'Engine: copia sana e pulizia riuscite'
    $days = @(Get-ChildItem -LiteralPath $fixture.Backups -Directory | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' })
    Assert-True ($days.Count -eq 1 -and $days[0].Name -eq (Get-Date -Format 'yyyy-MM-dd')) 'Engine: incompleti, residui pendenti e giorni vuoti rimossi'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Backups 'unrelated\keep.txt')) 'Engine: cartelle estranee conservate'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Backups '_logs\_pulizie-pendenti'))) 'Engine: recupero delle pulizie confermato'

    $fixture = New-EngineFixture 'unhealthy' $true
    Assert-True ((Invoke-EngineFixture $fixture 'unhealthy') -eq 104) 'Engine: volume degradato restituisce 104'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Previous 'previous.txt')) 'Engine: copia completa preservata sul volume degradato'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Backups '_logs\_pulizie-pendenti')) 'Engine: pulizia non avviata sul volume degradato'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Backups (Get-Date -Format 'yyyy-MM-dd')))) 'Engine: nessuno snapshot creato sul volume degradato'

    foreach ($scenario in @('degraded-after-copy', 'stats-failure')) {
        $fixture = New-EngineFixture $scenario $false
        Assert-True ((Invoke-EngineFixture $fixture $scenario) -eq 105) "Engine: $scenario restituisce 105"
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Previous 'previous.txt')) "Engine: $scenario conserva la copia precedente"
        $markers = @(Get-ChildItem -LiteralPath $fixture.Backups -Filter '_SNAPSHOT-INCOMPLETO.txt' -Recurse -Force)
        Assert-True ($markers.Count -eq 1) "Engine: $scenario mantiene la marcatura incompleta"
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Path '_logs\BACKUP-ERRORE.txt')) "Engine: $scenario lascia un rapporto sul disco locale"
    }

    $fixture = New-EngineFixture 'copy-failure' $false
    Assert-True ((Invoke-EngineFixture $fixture 'copy-failure') -eq 8) 'Engine: fallimento robocopy conserva il codice 8'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Previous 'previous.txt')) 'Engine: fallimento della copia conserva l''ultimo backup completo'
    $failReport = Join-Path $fixture.Backups '_logs\BACKUP-FALLITO-RILANCIARE.txt'
    Assert-True (Test-Path -LiteralPath $failReport) 'Engine: fallimento della copia genera il rapporto di rilancio'
    Assert-True ((Get-Content -LiteralPath $failReport -Raw) -like '*Log della ripresa*') 'Engine: il rapporto dice che la seconda passata e'' stata tentata'

    # Il guasto che robocopy conta e non racconta (2026-10-28). Prima di avere
    # la seconda passata, qui si buttava uno snapshot integro e il backup
    # restava indietro di un giorno.
    $fixture = New-EngineFixture 'silent-failure' $false
    Assert-True ((Invoke-EngineFixture $fixture 'silent-failure') -eq 0) 'Engine: guasto senza righe di errore recuperato dalla seconda passata'
    $today = Join-Path $fixture.Backups (Get-Date -Format 'yyyy-MM-dd')
    Assert-True (Test-Path -LiteralPath $today) 'Engine: lo snapshot recuperato resta su disco'
    Assert-True (@(Get-ChildItem -LiteralPath $fixture.Backups -Filter '_SNAPSHOT-INCOMPLETO.txt' -Recurse -Force).Count -eq 0) 'Engine: lo snapshot recuperato non resta marcato incompleto'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Backups '_logs\BACKUP-FALLITO-RILANCIARE.txt'))) 'Engine: nessun rapporto di fallimento dopo una ripresa riuscita'
    $storico = Get-Content -LiteralPath (Join-Path $fixture.Backups '_logs\storico-snapshot.txt') -Raw
    Assert-True ($storico -match '\|\s*OK\s*\|') 'Engine: lo snapshot recuperato e'' registrato come OK'
    Assert-True ($storico -match '\|\s*RIPRESA\s*\|') 'Engine: la seconda passata lascia traccia nello storico'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $fixture.Backups '_logs') -Filter '*_ripresa.log').Count -eq 1) 'Engine: il log della seconda passata resta accanto al primo'

    $fixture = New-EngineFixture 'only-partial' $false
    Set-Content -LiteralPath (Join-Path $fixture.Previous '_SNAPSHOT-INCOMPLETO.txt') -Value 'copia parziale da conservare'
    Assert-True ((Invoke-EngineFixture $fixture 'copy-failure') -eq 8) 'Engine: copia fallita senza backup completi restituisce 8'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Previous 'previous.txt')) 'Engine: unica copia parziale precedente conservata'
    Assert-True (@(Get-ChildItem -LiteralPath $fixture.Backups -Filter '_SNAPSHOT-INCOMPLETO.txt' -Recurse -Force).Count -eq 2) 'Engine: nessuna copia parziale eliminata quando mancano copie complete'

    # Disco saturo: il backup deve fermarsi PRIMA di scrivere, lasciando intatta
    # la copia precedente. E' lo scenario del 2026-10-16, dove invece la copia
    # parti', riempi' il volume e bloccò pure la pulizia.
    $fixture = New-EngineFixture 'low-space' $false
    $before = @(Get-ChildItem -LiteralPath $fixture.Backups -Directory -Force | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' }).Count
    Assert-True ((Invoke-EngineFixture $fixture 'low-space') -eq 107) 'Engine: disco saturo restituisce EXIT_LOW_SPACE'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Previous 'previous.txt')) 'Engine: disco saturo conserva l''ultimo backup completo'
    $after = @(Get-ChildItem -LiteralPath $fixture.Backups -Directory -Force | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' }).Count
    Assert-True ($after -eq $before) 'Engine: disco saturo non crea nessuna cartella-giorno nuova'

    $fixture = New-EngineFixture 'invalid-journal' $false
    $invalidJournal = Join-Path $fixture.Backups '_logs\_pulizie-pendenti'
    New-Item -ItemType Directory -Path $invalidJournal | Out-Null
    [IO.File]::WriteAllText((Join-Path $invalidJournal '2026-01-01.txt'), '')
    Assert-True ((Invoke-EngineFixture $fixture 'healthy') -eq 105) 'Engine: registro troncato blocca l''esecuzione'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Previous 'previous.txt')) 'Engine: registro invalido non provoca pulizie'

    $fixture = New-EngineFixture 'destination-junction' $false
    $escaped = Join-Path $fixture.Path 'escaped'
    New-Item -ItemType Directory -Path $escaped | Out-Null
    Set-Content -LiteralPath (Join-Path $escaped 'keep.txt') -Value 'protetto'
    $dayJunction = Join-Path $fixture.Backups (Get-Date -Format 'yyyy-MM-dd')
    New-Item -ItemType Junction -Path $dayJunction -Target $escaped | Out-Null
    try {
        Assert-True ((Invoke-EngineFixture $fixture 'healthy') -eq 105) 'Engine: giorno collegato fuori dalla radice bloccato prima della copia'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $escaped 'file.txt'))) 'Engine: nessuna scrittura attraverso il collegamento'
        Assert-True (Test-Path -LiteralPath (Join-Path $escaped 'keep.txt')) 'Engine: dati esterni al backup preservati'
    } finally { [IO.Directory]::Delete($dayJunction, $false) }

    $fixture = New-EngineFixture 'already-running' $false
    $busyMutex = New-Object System.Threading.Mutex($false, 'Global\BackupSviluppo')
    $busyLocked = $busyMutex.WaitOne(0)
    try {
        if (-not $busyLocked) { throw 'Un backup reale occupa il mutex: test interrotto.' }
        Assert-True ((Invoke-EngineFixture $fixture 'healthy') -eq 106) 'Engine: esecuzione sovrapposta restituisce 106, non successo'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Previous 'previous.txt')) 'Engine: esecuzione sovrapposta conserva il backup precedente'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Backups (Get-Date -Format 'yyyy-MM-dd')))) 'Engine: esecuzione sovrapposta non crea snapshot'
    } finally {
        if ($busyLocked) { $busyMutex.ReleaseMutex() }
        $busyMutex.Dispose()
    }

    $fixture = New-EngineFixture 'cleanup-failure' $false
    Assert-True ((Invoke-EngineFixture $fixture 'cleanup-failure') -eq 105) 'Engine: pulizia fallita non restituisce successo'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Backups '_logs\_pulizie-pendenti')) 'Engine: cancellazione fallita registrata fuori dallo snapshot'
    Start-Sleep -Milliseconds 1100
    Assert-True ((Invoke-EngineFixture $fixture 'healthy') -eq 0) 'Engine: rilancio sano recupera la pulizia interrotta'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Backups '_logs\_pulizie-pendenti'))) 'Engine: residui del tentativo precedente eliminati'

    # --- Analisi del log di robocopy e declassamento degli errori benigni ---
    # Il 2026-10-19 un solo prova.md di scratch, cancellato da un altro processo
    # mentre la copia era in corso, ha fatto scartare 25,6 GB di copia buona.
    $logRoot = Join-Path $testRoot 'robolog'
    New-Item -ItemType Directory -Path $logRoot | Out-Null
    $spariti = Join-Path $Source 'mai-esistito\effimero.md'
    $presente = Join-Path $Source 'presente.md'
    Set-Content -LiteralPath $presente -Value 'x' -Encoding UTF8

    function New-RoboLog([string]$Name, [string[]]$Lines) {
        $p = Join-Path $logRoot $Name
        Set-Content -LiteralPath $p -Value $Lines -Encoding Oem
        return $p
    }
    function Test-Declassabile([string]$LogPath) {
        $errs = @(Get-RobocopyLogErrors $LogPath)
        if ($errs.Count -eq 0) { return $false }
        return (@($errs | Where-Object { Test-VanishedSourceError $_ }).Count -eq $errs.Count)
    }

    $log = New-RoboLog 'vuoto.log' @('   Terminato: nessun errore')
    Assert-True (@(Get-RobocopyLogErrors $log).Count -eq 0) 'Log: nessun errore estratto da un log pulito'
    Assert-True (-not (Test-Declassabile $log)) 'Log: senza errori non si declassa nulla'

    $log = New-RoboLog 'effimero.log' @(
        ('2026/10/19 17:10:04 ERRORE 3 (0x00000003) Copia del file in corso ' + $spariti)
        'Impossibile trovare il percorso specificato.'
        'Attesa di 2 secondi... Nuovo tentativo in corso...'
        ('2026/10/19 17:10:34 ERRORE 3 (0x00000003) Copia del file in corso ' + $spariti)
        'Impossibile trovare il percorso specificato.')
    $errs = @(Get-RobocopyLogErrors $log)
    Assert-True ($errs.Count -eq 1) 'Log: lo stesso file fallito due volte conta una volta sola'
    Assert-True ($errs[0].Number -eq 3 -and $errs[0].Path -eq $spariti) 'Log: numero e percorso estratti dalla riga di errore'
    Assert-True (Test-Declassabile $log) 'Declassamento: file sparito durante la copia e assente ora'

    $log = New-RoboLog 'inglese.log' @(
        ('2026/10/19 17:10:04 ERROR 2 (0x00000002) Copying File ' + $spariti)
        'The system cannot find the file specified.')
    Assert-True (Test-Declassabile $log) 'Declassamento: riconosciuto anche su log in inglese (ERROR 2)'

    $log = New-RoboLog 'ricomparso.log' @(
        ('2026/10/19 17:10:04 ERRORE 3 (0x00000003) Copia del file in corso ' + $presente)
        'Impossibile trovare il percorso specificato.')
    Assert-True (-not (Test-Declassabile $log)) 'Declassamento negato: il percorso esiste di nuovo'

    $log = New-RoboLog 'misto.log' @(
        ('2026/10/19 17:10:04 ERRORE 3 (0x00000003) Copia del file in corso ' + $spariti)
        'Impossibile trovare il percorso specificato.'
        ('2026/10/19 17:10:05 ERRORE 5 (0x00000005) Copia del file in corso ' + $presente)
        'Accesso negato.')
    Assert-True (@(Get-RobocopyLogErrors $log).Count -eq 2) 'Log: errori distinti contati separatamente'
    Assert-True (-not (Test-Declassabile $log)) 'Declassamento negato: accanto al benigno c''e'' un errore 5'

    $log = New-RoboLog 'pieno.log' @(
        ('2026/10/19 17:10:04 ERRORE 112 (0x00000070) Copia del file in corso ' + $spariti)
        'Spazio su disco insufficiente.')
    Assert-True (-not (Test-Declassabile $log)) 'Declassamento negato: errore 112 non e'' mai benigno'

    $log = New-RoboLog 'fuorisorgente.log' @(
        '2026/10/19 17:10:04 ERRORE 3 (0x00000003) Copia del file in corso Q:\altrove\x.md'
        'Impossibile trovare il percorso specificato.')
    Assert-True (-not (Test-Declassabile $log)) 'Declassamento negato: percorso fuori dalla sorgente'

    Assert-True (@(Get-RobocopyLogErrors (Join-Path $logRoot 'inesistente.log')).Count -eq 0) 'Log: file di log assente non fa eccezione'

    # --- Riepilogo finale di robocopy (2026-10-28) ----------------------
    # Numeri veri della copia che si e' persa una directory senza scriverne
    # niente nel log: finche' si guardavano le sole righe di errore, qui non
    # risultava nessun guasto da spiegare.
    $log = New-RoboLog 'riepilogo.log' @(
        '              Totale   Copiato  IgnorateNon corrispondentiNon riuscitaSupplementari'
        'Directory:     20945     20791       155         0         1         0'
        '     File:    195088    195072        16         0         0         1'
        '     Byte:  28.274 g  28.274 g    42.3 k         0         0       300'
        '   Durata:  11:24:56   0:23:31                       0:00:00   0:00:52')
    $sum = Get-RobocopySummary $log
    Assert-True ($sum.Found -and $sum.DirsFailed -eq 1 -and $sum.FilesFailed -eq 0) 'Riepilogo: guasto contato anche senza nessuna riga di errore'
    Assert-True ($sum.DirsTotal -eq 20945 -and $sum.FilesTotal -eq 195088) 'Riepilogo: totali letti dalla tabella'

    $log = New-RoboLog 'riepilogo-en.log' @(
        '               Total    Copied   Skipped  Mismatch    FAILED    Extras'
        '    Dirs :        12        11         0         0         1         0'
        '   Files :       100        98         0         0         2         0'
        '   Bytes :     1.0 m     1.0 m         0         0         0         0'
        '   Times :   0:00:11   0:00:01                       0:00:00   0:00:00')
    $sum = Get-RobocopySummary $log
    Assert-True ($sum.Found -and $sum.DirsFailed -eq 1 -and $sum.FilesFailed -eq 2) 'Riepilogo: letto per posizione, quindi anche su Windows in inglese'

    $log = New-RoboLog 'senza-riepilogo.log' @('   Terminato: copia interrotta')
    Assert-True (-not (Get-RobocopySummary $log).Found) 'Riepilogo: log senza tabella non inventa numeri'
    Assert-True (-not (Get-RobocopySummary (Join-Path $logRoot 'inesistente.log')).Found) 'Riepilogo: log assente non fa eccezione'

    Write-Host "Verifiche superate: $passed"
} finally {
    # Target fisso creato da questo test, verificato prima della rimozione ricorsiva.
    $resolvedTestRoot = (Get-Item -LiteralPath $testRoot -Force).FullName.TrimEnd('\')
    if (-not [string]::Equals($resolvedTestRoot, $testRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $resolvedTestRoot.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\sync-dev-test-'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Percorso temporaneo di test non sicuro: pulizia bloccata.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction Stop
}
