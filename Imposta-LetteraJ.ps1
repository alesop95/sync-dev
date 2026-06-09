<#
    Imposta-LetteraJ.ps1
    Assegna la lettera attesa ($ExpectedDriveLetter) alla partizione dati del disco atteso
    ($ExpectedDiskModel / $ExpectedDiskSerial). Windows poi riassegna quella lettera al disco
    a ogni collegamento, se la lettera e' libera.
    DA ESEGUIRE come Amministratore. Parametri in Config-sync-dev.ps1.
#>

. (Join-Path $PSScriptRoot 'Config-sync-dev.ps1')

$target = $ExpectedDriveLetter

$disks = @(Get-Disk | Where-Object {
    ($_.FriendlyName -like $ExpectedDiskModel) -and
    (($ExpectedDiskSerial -eq '') -or ((("$($_.SerialNumber)").Trim()) -eq $ExpectedDiskSerial.Trim()))
})

if ($disks.Count -eq 0) {
    Write-Host "Disco atteso non trovato. Collega il dispositivo e verifica il modello/serial con Mostra-Dischi.ps1."
    return
}
if ($disks.Count -gt 1) {
    Write-Host "Trovati piu' dischi corrispondenti al modello. Imposta un numero di serie esatto in `$ExpectedDiskSerial."
    return
}
$disk = $disks[0]

# Partizione dati: la piu' grande non riservata
$part = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -ne 'Reserved' } |
        Sort-Object Size -Descending | Select-Object -First 1
if (-not $part) {
    Write-Host "Nessuna partizione utilizzabile sul disco '$($disk.FriendlyName)'."
    return
}

# La lettera attesa e' gia' occupata da un altro disco?
$busy = Get-Partition -DriveLetter $target -ErrorAction SilentlyContinue
if ($busy -and $busy.DiskNumber -ne $disk.Number) {
    Write-Host "La lettera ${target}: e' gia' usata da un altro disco (Disco $($busy.DiskNumber)). Liberala e riprova."
    return
}
if ($part.DriveLetter -eq $target) {
    Write-Host "Il disco '$($disk.FriendlyName)' ha gia' la lettera ${target}:. Nessuna modifica."
    return
}

if ($part.DriveLetter) {
    Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter $target
} else {
    Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AccessPath "${target}:\"
}
Write-Host "Assegnata la lettera ${target}: al disco '$($disk.FriendlyName)'. Windows la manterra' ai prossimi collegamenti."
