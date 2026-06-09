<#
    Watcher-Backup.ps1
    Resta in ascolto degli eventi di connessione dei volumi.
    Quando J: viene collegato (SSD esterno), lancia il backup "al primo momento disponibile".
    Avviato all'avvio del sistema dal task "Backup Sviluppo - Watcher J".
#>

$BackupScript = 'C:\Scripts\sync-dev\Backup-Sviluppo.ps1'
$WatchDrive   = 'J:'

function Start-Backup {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $BackupScript) `
        -WindowStyle Hidden
}

# Se J: e' gia' collegato all'avvio, fai subito un backup di recupero.
if (Test-Path -LiteralPath "$WatchDrive\") { Start-Backup }

# EventType 2 = arrivo di un dispositivo (Win32_VolumeChangeEvent).
$query = "SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2"

Register-CimIndicationEvent -Query $query -SourceIdentifier 'JArrival' -Action {
    $drive = $Event.SourceEventArgs.NewEvent.DriveName   # es. "J:"
    if ($drive -eq 'J:') {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','C:\Scripts\sync-dev\Backup-Sviluppo.ps1') `
            -WindowStyle Hidden
    }
} | Out-Null

# Mantiene vivo il processo: l'iscrizione agli eventi resta attiva finche' il task gira.
while ($true) { Wait-Event -Timeout 3600 | Out-Null }
