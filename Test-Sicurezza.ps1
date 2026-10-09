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
function Get-Volume {
    [CmdletBinding()] param([string]$DriveLetter)
    if ($script:volumeThrows) { throw 'Query volume non disponibile' }
    return $script:mockVolumes
}
$mockVolumes = @([pscustomobject]@{ HealthStatus = 'Healthy'; OperationalStatus = @('OK'); FileSystemType = 'exFAT' })
$volumeThrows = $false

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
function Test-BackupDevice { [pscustomobject]@{ Ok = $true; Status = 'OK'; Reason = '' } }
function Get-Volume {
    [CmdletBinding()] param([string]$DriveLetter)
    $bad = $script:scenario -eq 'unhealthy' -or ($script:scenario -eq 'degraded-after-copy' -and $script:copyCalled)
    [pscustomobject]@{
        HealthStatus = $(if ($bad) { 'Warning' } else { 'Healthy' })
        OperationalStatus = @($(if ($bad) { 'Full Repair Needed' } else { 'OK' }))
        FileSystemType = 'exFAT'
    }
}
function robocopy {
    param([Parameter(ValueFromRemainingArguments=$true)][object[]]$RoboArgs)
    $script:copyCalled = $true
    if ($script:scenario -eq 'copy-failure') { $global:LASTEXITCODE = 8; return }
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
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Backups '_logs\BACKUP-FALLITO-RILANCIARE.txt')) 'Engine: fallimento della copia genera il rapporto di rilancio'

    $fixture = New-EngineFixture 'only-partial' $false
    Set-Content -LiteralPath (Join-Path $fixture.Previous '_SNAPSHOT-INCOMPLETO.txt') -Value 'copia parziale da conservare'
    Assert-True ((Invoke-EngineFixture $fixture 'copy-failure') -eq 8) 'Engine: copia fallita senza backup completi restituisce 8'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Previous 'previous.txt')) 'Engine: unica copia parziale precedente conservata'
    Assert-True (@(Get-ChildItem -LiteralPath $fixture.Backups -Filter '_SNAPSHOT-INCOMPLETO.txt' -Recurse -Force).Count -eq 2) 'Engine: nessuna copia parziale eliminata quando mancano copie complete'

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
