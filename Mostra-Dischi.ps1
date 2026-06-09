<#
    Mostra-Dischi.ps1
    Elenca i dischi collegati con lettera, modello (FriendlyName), numero di serie e bus.
    Usa questo output per impostare con precisione $ExpectedDiskModel e/o $ExpectedDiskSerial
    in Config-sync-dev.ps1. Consigliato eseguirlo come Amministratore.
#>

Get-Disk | ForEach-Object {
    $letters = (Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
                Where-Object DriveLetter |
                Select-Object -ExpandProperty DriveLetter) -join ','
    [pscustomobject]@{
        Disco   = $_.Number
        Lettere = $letters
        Modello = $_.FriendlyName
        Serial  = ("$($_.SerialNumber)").Trim()
        Bus     = $_.BusType
        SizeGB  = [math]::Round($_.Size / 1GB, 1)
    }
} | Sort-Object Disco | Format-Table -AutoSize
