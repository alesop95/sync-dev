# sync-dev: backup locale con conferma, verifica del dispositivo e snapshot datati

Soluzione di backup locale per Windows 11 basata su strumenti nativi (robocopy,
Utilita' di pianificazione, PowerShell). Nessun software di terze parti, nessun
servizio cloud. Agli orari previsti compare un pop-up di conferma: se accettato,
e se il disco di backup e la sorgente superano le verifiche, viene creato uno
snapshot datato della sorgente sul disco di backup. Gli snapshot piu' vecchi di
una finestra configurabile vengono eliminati automaticamente.

Caratteristiche principali:

- Verifica dell'identita' del disco di backup: la copia parte solo se la lettera
  attesa punta esattamente al dispositivo atteso (per modello e, opzionalmente,
  numero di serie). Tutto e' parametrizzabile in un unico file.
- Verifica della sorgente: se la sorgente non e' rilevata, la copia si blocca e
  viene mostrato un alert; la sorgente puo' essere riconfigurata in un punto solo.
- Verifica del volume prima delle scritture e dopo la copia: serve lo stato
  `Healthy / OK`. Un volume degradato o non verificabile blocca copia e pulizia.
- Tetto di tempo sulle interrogazioni dei dischi: un dispositivo guasto
  qualunque della macchina, anche estraneo al backup, puo' bloccare per sempre
  `Get-Volume`. Scaduto il tetto l'engine si ferma con codice 108, nomina il
  disco su cui Windows sta ripetendo le operazioni e non scrive niente
  (sezione 7).
- Verifica dello spazio libero prima di scrivere: se il disco non ha spazio per
  il nuovo snapshot la copia si blocca con codice 107 e il disco resta com'era.
  Serve a non saturare il volume, perche' un disco pieno non fa solo fallire la
  copia: impedisce pure la pulizia che libererebbe spazio (sezione 7).
- Pulizia verificata e ripresa dei residui: le cancellazioni iniziate restano
  registrate fuori dall'albero eliminato finche' la rimozione non e' confermata.
  Gli errori di I/O o retention impediscono di dichiarare riuscita l'esecuzione.
- Snapshot datati con retention a finestra di giorni solari (oggi incluso) e
  sul numero di snapshot: resta solo l'ultima copia completa.
- Seconda passata prima di buttare una copia: se robocopy segnala "alcuni file
  non copiati" senza un errore grave, l'engine ripete la copia sullo stesso
  snapshot e la scarta solo se fallisce di nuovo. Serve ai guasti transitori e a
  quelli che robocopy conta nel riepilogo senza scriverli nel log (sezione 9).
- Memoria degli snapshot incompleti: se robocopy termina con file mancanti, lo
  snapshot difettoso viene eliminato subito, resta solo l'ultima copia completa
  e in `_logs` viene scritto un rapporto con i file non copiati e i comandi per
  rilanciare.
- Doppio log: storico cumulativo permanente piu' log dettagliati con retention.

## Indice
1. Panoramica
2. Contenuto del repository
3. Configurazione
4. Verifica dell'identita' del disco di backup
5. Lettera di unita' fissa
6. Installazione
7. Comportamento a runtime
8. Struttura su disco
9. Retention
10. Logging
11. Verifica
12. Ripristino
13. Manutenzione
14. Limiti
15. Modalita' automatica (alternativa)
16. Codici di uscita
17. Controllo di versione e dati sensibili

## 1. Panoramica

Componenti:

- robocopy: motore di copia incluso in Windows.
- Utilita' di pianificazione: avvia il processo agli orari configurati.
- PowerShell: configurazione, verifiche, pop-up di conferma, copia e
  registrazione del task.

Flusso: agli orari previsti, un task pianificato in sessione utente esegue lo
script di conferma, che mostra un pop-up. Alla conferma, l'engine verifica che
il disco di backup sia il dispositivo atteso e che la sorgente sia presente;
solo allora avvia robocopy verso una cartella datata, aggiorna i log e applica
la retention. Se una verifica fallisce, non viene copiato nulla e viene mostrato
un alert specifico.

Valori predefiniti (modificabili, vedi sezione 3):

- Sorgente: `E:\`
- Disco di backup: lettera `J`, modello `*Samsung*T7*`
- Radice degli snapshot: `J:\backup-sviluppo`
- Cartella degli script: `E:\sync-dev`

## 2. Contenuto del repository

| File | Ruolo |
|------|-------|
| `Config-sync-dev.ps1` | Parametri e funzioni condivise (caricato dagli altri script) |
| `Sicurezza-Backup.ps1` | Stato del volume, confini della pulizia, registro delle cancellazioni pendenti e diagnostica locale |
| `Backup-Sviluppo.ps1` | Verifica disco e sorgente, crea lo snapshot, scrive i log, marca le copie incomplete, applica la retention |
| `Backup-Conferma.ps1` | Mostra il pop-up; richiama l'engine e mostra esito o alert |
| `Registra-Task-Conferma.ps1` | Registra il task pianificato (una tantum) |
| `Mostra-Dischi.ps1` | Elenca i dischi collegati con lettera, modello, serial e bus |
| `Imposta-LetteraJ.ps1` | Assegna la lettera attesa al disco atteso |
| `README.md` | Questo documento |
| `Test-Sicurezza.ps1` | Regressioni su file temporanei e volumi simulati, senza usare sorgente reale o disco di backup |

File della modalita' automatica alternativa (non attivi, vedi sezione 15):

| File | Ruolo |
|------|-------|
| `Registra-Task.ps1` | Registra i task automatici (orari + watcher) |
| `Watcher-Backup.ps1` | Avvia la copia al collegamento del disco di backup |

Tutti gli script devono risiedere nella stessa cartella (`E:\sync-dev`),
perche' si caricano a vicenda tramite percorso relativo allo script.

## 3. Configurazione

Tutti i parametri sono in cima a `Config-sync-dev.ps1`, file unico caricato in
dot-source dagli altri script.

| Variabile | Default | Significato |
|-----------|---------|-------------|
| `$Source` | `E:\` | Volume o cartella sorgente |
| `$SourceLabel` | `sorgente progetti` | Descrizione usata nei messaggi |
| `$ExpectedDriveLetter` | `J` | Lettera che il disco di backup deve avere |
| `$ExpectedDiskModel` | `*Samsung*T7*` | Confronto -like sul nome del disco |
| `$ExpectedDiskSerial` | (vuoto) | Numero di serie esatto; vuoto = non controllato |
| `$BackupRoot` | `J:\backup-sviluppo` | Radice degli snapshot (derivata dalla lettera) |
| `$RetainDays` | `1` | Giorni solari conservati, oggi incluso: 1 = resta solo il giorno corrente (minimo effettivo 1) |
| `$RetainSnapshots` | `1` | Snapshot completi conservati in totale, i piu' recenti: 1 = resta solo l'ultima copia, quella del pomeriggio sostituisce quella del mattino (minimo effettivo 1) |
| `$ExcludeDirs` | vedi file | Cartelle escluse dalla copia (per nome, a ogni profondita', oppure per percorso assoluto) |
| `$ExcludeFiles` | vedi file | Pattern di file esclusi |
| `$SpaceSafetyFactor` | `1.8` | Moltiplicatore sulla dimensione logica dell'ultimo snapshot per stimare quella reale. `1.8` su exFAT con cluster da 128 KB (misurato fra 1,62x e 1,85x), `1.15` basta su NTFS con cluster da 4 KB |
| `$MinFreeMarginGB` | `5` | Margine libero preteso oltre alla stima, in GB |
| `$RetryCopyOnFailure` | `$true` | Seconda passata di robocopy quando la prima torna con "alcuni file non copiati" (bit 8) ma non con un errore grave (bit 16): ricopia cio' che manca e non cancella niente (sezione 9) |

Per cambiare modello di SSD in futuro, basta aggiornare `$ExpectedDiskModel` ed
eventualmente `$ExpectedDiskSerial`. Per cambiare sorgente, basta aggiornare
`$Source`. Nessun altro file va modificato.

Cartelle escluse di default (rigenerabili nei progetti full-stack):
`node_modules`, `.pnpm-store`, `.pnpm`, `dist`, `build`, `out`, `.next`,
`.nuxt`, `.svelte-kit`, `target`, `__pycache__`, `.venv`, `venv`, `.tox`,
`.pytest_cache`, `.cache`, `.parcel-cache`, `.turbo`, `.gradle`, `coverage`.
La cartella `.git` e' inclusa per default; per escluderla, rimuovere il commento
alla riga relativa.

File esclusi di default: `*.tmp`, `Thumbs.db`, `.DS_Store`, e dal 2026-09-30 i
backup di macchina Veeam Agent, cioe' `*.vbk` (full), `*.vib` (incrementale) e
`*.vbm` (metadati), per estensione e a ogni profondita'. Un punto di ripristino
pesa decine di GB e non cambia: se finisse sotto la sorgente verrebbe ricopiato
ogni giorno sull'SSD per duplicare una copia statica. L'esclusione vale finche' i
backup non avranno una destinazione propria sul NAS domestico. Le estensioni
vengono dalla guida "Types of Backup Files" di Veeam Agent for Linux:
https://helpcenter.veeam.com/docs/agentforlinux/userguide/backup_files.html

Dal 2026-10-05 sono esclusi anche i messaggi di commit temporanei,
`COMMIT-MSG*.txt` (tipicamente `_notes\COMMIT-MSG.txt`). Vengono consumati da un
commit e cancellati, a volte mentre la copia e' in corso: robocopy trovava il
file in elenco ma non piu' su disco e chiudeva con `ERRORE 2 (0x00000002)`. Il
loro contenuto resta comunque nella history git. Il suffisso `.txt` evita di
escludere gli hook git `commit-msg`, che non hanno estensione.

### Esclusioni aggiunte il 2026-10-16

`E:\retrogame-mod-pok-dev\_notes\fonti\cloni` — cloni di repository di terze
parti (pokeemerald e simili) tenuti come fonte di consultazione: 49.604 file per
appena 0,20 GB di contenuto, che su exFAT con cluster da 128 KB diventano 6,13
GB. Il 97% e' slack, e il contenuto si ricrea con un `git clone`.

`E:\sync-dev\_logs` — da quando il progetto vive su `E:\` sta dentro la propria
sorgente, e l'engine scrive qui mentre robocopy sta copiando questa cartella: un
file che nasce o cambia a copia in corso e' lo stesso incidente gia' visto con
`COMMIT-MSG*.txt`. Gli script restano nello snapshot, solo i log no.

### Perche' `.git` resta incluso

Una verifica del 2026-10-16 sui 41 repository di `E:\` ha trovato due casi che
rendono l'esclusione inaccettabile: `my-wedding-day` ha 16 commit non pushati e
`serp.systems-full-early_mvp` non ha alcun remoto, quindi la sua storia esiste
solo su questo disco. Escludere `.git` li perderebbe in silenzio. Il costo
attuale e' 5,00 GB su exFAT per 0,92 GB logici, su 34.544 file. L'esclusione
torna valutabile solo dopo aver dato un remoto a ogni repository.

## 4. Verifica dell'identita' del disco di backup

Prima di ogni copia, l'engine controlla che la lettera attesa esista e punti
esattamente al dispositivo atteso. Il controllo avviene in tre passaggi:

1. Esiste un disco con la lettera `$ExpectedDriveLetter`? In caso negativo, il
   backup si blocca (disco non collegato come lettera attesa).
2. Il nome del disco (FriendlyName) corrisponde a `$ExpectedDiskModel`? In caso
   negativo, il backup si blocca (dispositivo diverso da quello atteso).
3. Se `$ExpectedDiskSerial` e' valorizzato, il numero di serie corrisponde? In
   caso negativo, il backup si blocca.

Il modello da solo identifica una categoria di dischi (qualsiasi Samsung T7); il
numero di serie identifica il singolo esemplare. Per la massima precisione,
impostare anche `$ExpectedDiskSerial`. Per scoprire modello e serial esatti del
proprio dispositivo, eseguire:

```powershell
E:\sync-dev\Mostra-Dischi.ps1
```

Copiare il valore della colonna Modello in `$ExpectedDiskModel` (con eventuali
asterischi come caratteri jolly) e, se desiderato, il valore della colonna
Serial in `$ExpectedDiskSerial`.

## 5. Lettera di unita' fissa

Il requisito e' che il disco di backup prenda sempre la lettera attesa quando
collegato. Windows ricorda l'assegnazione di lettera per ciascun volume, quindi
basta impostarla una volta. Due modalita':

Automatica (parametrica), con il disco collegato e PowerShell come Amministratore:

```powershell
E:\sync-dev\Imposta-LetteraJ.ps1
```

Lo script individua il disco atteso, assegna la lettera attesa alla sua
partizione dati e segnala se la lettera e' gia' occupata da un altro disco.

Manuale: Gestione disco di Windows, tasto destro sulla partizione del disco,
Cambia lettera e percorso di unita', impostare la lettera attesa.

Se il disco e' presente ma con una lettera diversa (per esempio perche' la
lettera attesa era occupata), la verifica della sezione 4 fallisce e il backup
viene bloccato, come richiesto.

## 6. Installazione

Sequenza cronologica completa, da eseguire in ordine. Lo sblocco dei file (passo
3) e' parte integrante della sequenza, non un dettaglio: senza di esso gli script
vengono bloccati dai criteri di esecuzione.

1. Copiare tutti gli script nella cartella `E:\sync-dev`.
2. Aprire PowerShell come Amministratore (con il proprio account).
3. Sbloccare i file e abilitare l'esecuzione degli script locali (lo scope
   CurrentUser non richiede privilegi di amministratore):

   ```powershell
   Get-ChildItem E:\sync-dev\*.ps1 | Unblock-File
   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
   ```

   REGOLA DA RICORDARE: ripetere il comando Unblock-File ogni volta che si
   aggiunge o si sostituisce uno script (un file appena scaricato e' di nuovo
   contrassegnato come proveniente da Internet e quindi bloccato). Se la
   configurazione non si carica, gli script lo segnalano e invitano a eseguire
   Unblock-File.
4. Collegare il disco di backup.
5. Scoprire i parametri del disco ed eventualmente aggiornarli in
   `Config-sync-dev.ps1`:

   ```powershell
   E:\sync-dev\Mostra-Dischi.ps1
   ```

6. Assegnare la lettera attesa al disco (se non gia' impostata):

   ```powershell
   E:\sync-dev\Imposta-LetteraJ.ps1
   ```

7. Registrare il task pianificato:

   ```powershell
   E:\sync-dev\Registra-Task-Conferma.ps1
   ```

8. Verificare che il task sia stato creato:

   ```powershell
   Get-ScheduledTask -TaskName 'Backup Sviluppo (con conferma)'
   ```

Note sul passo 7: `Registra-Task-Conferma.ps1` non mostra alcun pop-up, va
eseguito una sola volta e serve solo a creare il task. Se viene lanciato mentre
gli script sono ancora bloccati (passo 3 non eseguito), viene interrotto e il
task non viene creato.

Il task pianificato gira con -ExecutionPolicy Bypass, quindi non e' influenzato
dai criteri di esecuzione. Per una prova singola manuale senza modificare i
criteri si puo' usare `powershell -ExecutionPolicy Bypass -File <percorso>`.

Nella GUI il task si trova nella radice della Libreria Utilita' di pianificazione
(premere F5 per aggiornare la vista). Per provare subito il pop-up senza attendere
gli orari, avviare il task manualmente (tasto destro, Esegui) oppure lanciare
`Backup-Conferma.ps1`.

Se in precedenza era stata registrata la modalita' automatica, rimuoverla per
evitare doppie esecuzioni:

```powershell
Unregister-ScheduledTask -TaskName 'Backup Sviluppo E to J' -Confirm:$false
Unregister-ScheduledTask -TaskName 'Backup Sviluppo - Watcher J' -Confirm:$false
```

## 7. Comportamento a runtime

Ruoli dei file: `Registra-Task-Conferma.ps1` crea il task pianificato (una sola
volta); il task e' il timer che compare nell'Utilita' di pianificazione;
`Backup-Conferma.ps1` e' lo script che il task lancia agli orari e che mostra il
pop-up; `Backup-Sviluppo.ps1` e' l'engine che esegue verifiche e copia.

Agli orari configurati, se l'utente e' connesso alla sessione, compare un
pop-up di conferma in primo piano, con timeout configurabile.

- Conferma (Si): l'engine esegue le verifiche e, se superate, crea lo snapshot,
  applica la retention e mostra l'esito.
- Rifiuto (No) o timeout: non viene eseguita alcuna copia.
- Disco di backup assente o diverso da quello atteso: alert dedicato, nessuna
  copia.
- Sorgente non rilevata: alert dedicato che invita a riconfigurare la sorgente,
  nessuna copia.

Il task gira come utente loggato (non come SYSTEM), condizione necessaria per
mostrare una finestra nella sessione interattiva. Un mutex globale impedisce
esecuzioni sovrapposte; se un'esecuzione precedente e' stata terminata a forza
il mutex risulta "abbandonato" e viene comunque acquisito.

Lanciato a mano, l'engine stampa le fasi con l'orario (copia, conteggio,
retention, fine). Durante la copia robocopy non mostra avanzamento (circa 10-15
minuti con la sorgente attuale): la finestra non e' bloccata e non va chiusa. Gli esiti delle verifiche sono comunicati al pop-up
tramite i codici di uscita della sezione 16.

La fine della copia robocopy non coincide con la fine del backup: restano il
conteggio, la verifica del volume e la pulizia, che possono durare diversi
minuti con centinaia di migliaia di file. Se la copia e' uscita con errori non
gravi, prima del conteggio si inserisce una seconda passata di robocopy sullo
stesso snapshot, che allunga l'esecuzione del tempo di una nuova enumerazione
della sorgente (sezione 9). Attendere il messaggio finale, poi
richiedere la rimozione sicura da Windows e attendere che sia autorizzata.
Una richiesta di espulsione rifiutata significa che il dispositivo e' ancora
occupato, anche se la fase di copia e' gia' terminata.

Prima di ogni scrittura sul disco di backup, `Get-Volume` deve restituire
`HealthStatus = Healthy` e tutti gli `OperationalStatus = OK`. In caso diverso,
o se il controllo non riesce, l'engine si ferma con codice 104 e lascia il
dettaglio in `_logs\BACKUP-ERRORE.txt` accanto agli script, sul disco locale.
Il controllo viene ripetuto dopo il conteggio e prima di ogni cancellazione.

### Tetto di tempo sulle interrogazioni dei dischi (codice 108)

`Get-Volume`, `Get-Partition` e `Get-Disk` non hanno un timeout proprio. Per
rispondere passano dal provider Storage di Windows, che a sua volta interroga
tutti i dischi della macchina: basta un solo dispositivo guasto, anche uno che
con il backup non c'entra niente, perche' il provider resti appeso sui suoi
retry e la chiamata non torni mai.

Il 2026-10-23 e' successo. Una chiavetta USB montata su `G:` smette di
rispondere alle 10:02 (eventi `disk` ID 153 a raffica, LBA `0x0`, disco 4) e il
backup delle 16:50 si ferma dentro la guardia sul volume. Quarantadue minuti con
zero CPU, zero I/O, nessun log, nessuna riga nello storico, nessun pop-up: il
disco di backup stava benissimo, il pop-up di conferma aspettava un engine che
non sarebbe mai tornato e da fuori il backup sembrava soltanto lungo. La copia
delle 12:39 dello stesso giorno era riuscita, quindi non c'era nemmeno un
fallimento a cui appoggiarsi per accorgersene.

Da allora ogni interrogazione passa per `Invoke-StorageQuery`
(`Sicurezza-Backup.ps1`), che la esegue su un runspace separato e si arrende
dopo `$StorageQueryTimeoutSec` secondi (45 di default) lanciando
`TimeoutException`. Le guardie distinguono quel caso da tutti gli altri e
l'engine esce con codice 108: non 103 ("disco non collegato") e non 107 ("disco
pieno"), che manderebbero a cercare il guasto nel posto sbagliato.

Il messaggio nomina il colpevole quando riesce a riconoscerlo:
`Get-StorageRetrySuspects` legge dal registro eventi i dischi su cui Windows sta
ripetendo le operazioni di I/O nell'ultima ora e li cita nel rapporto locale e
nel pop-up. Il rimedio e' scollegare o ricollegare quel dispositivo, non
riparare il disco di backup.

Il thread rimasto appeso dentro il provider non si puo' interrompere: `Stop()` e
`Dispose()` aspetterebbero proprio la chiamata che non torna, riproducendo lo
stallo che si sta evitando. Viene quindi abbandonato: e' un thread di background
e non trattiene l'uscita del processo.

### La trappola dell'adattatore di tipi (regressione del 2026-10-26)

Il primo backup eseguito dopo l'introduzione del tetto di tempo si e' bloccato
con codice 104 su un volume perfettamente sano:

```
BLOCCATO: Volume J: (16) non sano: 0 / 2
```

`16`, `0` e `2` sono `exFAT`, `Healthy` e `OK` nella forma numerica con cui il
provider li restituisce davvero. Quelle parole non stanno nell'oggetto: le
produce l'adattatore di tipi del modulo Storage, e l'adattatore vive nel
runspace in cui il modulo e' stato caricato. L'engine gira come processo nuovo
e non chiama mai `Get-Volume` nel runspace principale, quindi li' l'adattatore
non c'e', l'oggetto arriva con i codici grezzi e il confronto con le stringhe
boccia un volume sano.

La correzione sta in `Get-VolumeInfoFromProvider`: i valori vengono proiettati
in un `pscustomobject` di stringhe vere **dentro** il runspace, dove il modulo
e' caricato, cosi' chi chiama non dipende piu' da nessun adattatore.

I test non l'avevano intercettata, ed e' la parte istruttiva. Gli stub
sostituivano il punto di aggancio proprio dove si attraversa il confine fra
runspace, e restituivano stringhe: quel confine non veniva mai percorso. Il
punto di aggancio che rendeva i test puliti era esattamente cio' che nascondeva
il difetto. La prova dal vivo del 2026-10-23 non lo aveva visto per un secondo
motivo: il provider era impiantato, l'engine si fermava al timeout e non
arrivava mai a leggere un volume, quindi il caso in cui le cose funzionano non
era mai stato esercitato.

Da qui due scelte. Le cinque verifiche che interrogano il provider **reale** in
sola lettura e falliscono se tornano codici invece di parole; e la separazione
fra `Get-BackupVolumeInfo`, che i test sostituiscono per simulare i volumi, e
`Get-VolumeInfoFromProvider`, che non viene sostituita mai e resta percorribile
dal vero.

Il guasto che ha fatto nascere tutto questo, e le impostazioni di Windows che
lo hanno favorito, sono documentati in `docs\18_USB_SOSPENSIONE_E_SUPPORTI_RIMOVIBILI.md`
del progetto `windows-status`.

### Guardia sullo spazio libero (codice 107)

Dopo il recupero dei residui e prima di creare qualsiasi cartella, l'engine
stima quanto occupera' il nuovo snapshot e lo confronta con lo spazio libero.
Se non basta, si ferma con codice 107 e il disco resta esattamente com'era.

La stima e' `dimensione logica dell'ultimo snapshot riuscito` (letta da
`storico-snapshot.txt`, quindi senza costi di scansione) moltiplicata per
`$SpaceSafetyFactor`, piu' `$MinFreeMarginGB`. Il moltiplicatore serve perche'
su un file system a cluster grandi l'occupazione reale supera di molto quella
logica: il costo non dipende dai byte ma dal numero di file, visto che ognuno
consuma un cluster intero anche se contiene 80 byte. Misure su `J:`:

| Snapshot | Logico | Reale | Rapporto | File |
|----------|--------|-------|----------|------|
| 2026-10-15 | 25,55 GB | 47,28 GB | 1,85x | 205.298 |
| 2026-10-16 | 26,06 GB | 46,57 GB | 1,79x | 195.524 |
| 2026-10-16 (cloni esclusi) | 25,92 GB | 41,93 GB | 1,62x | 157.846 |

Il rapporto scende man mano che si escludono le cartelle a molti file minuscoli.
Conviene quindi ricontrollare `$SpaceSafetyFactor` quando si cambiano le
esclusioni: un valore troppo prudente non protegge niente, fa solo saltare il
backup. Su una destinazione NTFS con cluster da 4 KB basta `1.15`.

La guardia non esiste per cortesia verso l'utente, ma perche' un volume portato
a saturazione non si limita a far fallire la copia. Il 2026-10-16 `J:` e'
arrivato a 0 byte liberi durante robocopy; alla pulizia successiva l'engine non
e' riuscito a scrivere nemmeno il record da poche centinaia di byte del registro
delle pulizie, e senza quel record la cancellazione che avrebbe liberato spazio
non e' partita. Disco pieno, pulizia impossibile, disco pieno: da li' non si
esce da soli. In piu' un exFAT tenuto a saturazione si corrompe, e su `J:` sono
comparse le cartelle di recupero `FOUND.000`, `FOUND.001` e `FOUND.002`.

Quando il blocco scatta, il messaggio elenca anche gli snapshot incompleti
presenti e quanto spazio libererebbero: senza quell'indicazione il codice 107
sarebbe un vicolo cieco nel caso peggiore, cioe' quando non esiste nessuna copia
completa, l'engine conserva per prudenza una copia troncata ed e' proprio quella
a occupare lo spazio che servirebbe per farne una buona. La decisione se
sacrificarla resta all'operatore.

Lo stesso incidente ha lasciato una seconda difesa: se il registro delle pulizie
non e' scrivibile sulla destinazione, il record finisce in uno specchio locale
accanto agli script (`_logs\_pulizie-pendenti`), cosi' la cancellazione puo'
comunque partire. `Get-PendingCleanup` legge l'unione dei due registri.
L'engine non avvia riparazioni del volume.

## 8. Struttura su disco

```
J:\backup-sviluppo\
  2026-06-09\
    12-31-04\
      _SNAPSHOT-INCOMPLETO.txt   (solo se la copia e' stata interrotta o ha avuto file mancanti)
    17-50-12\
  _logs\
    storico-snapshot.txt
    backup_AAAAMMGG_HHMMSS.log
    BACKUP-FALLITO-RILANCIARE.txt   (solo dopo una copia con errori, fino al rilancio riuscito)
    _pulizie-pendenti\             (solo finche' esistono cancellazioni non concluse)
      AAAA-MM-GG_HH-mm-ss.txt      (un record per snapshot o giorno in eliminazione)
```

Ogni esecuzione confermata e validata crea una cartella `AAAA-MM-GG\HH-mm-ss`
contenente una copia completa e indipendente della sorgente (escluse le cartelle
in `$ExcludeDirs`). Il backup gira due volte al giorno, ma con
`$RetainSnapshots = 1` dopo ogni copia riuscita resta una sola sottocartella,
quella appena creata: lo snapshot del mattino viene eliminato dal backup del
pomeriggio. Con `$RetainDays = 1` esiste una sola cartella-giorno alla volta,
quella corrente: le precedenti vengono eliminate a fine copia (sezione 9).

`_SNAPSHOT-INCOMPLETO.txt` e' il file sentinella che marca uno snapshot non
affidabile: robocopy non ha copiato tutti i file (codice di uscita >= 8) oppure
la copia non si e' conclusa (Ctrl+C, finestra chiusa, spegnimento). Il file viene
scritto all'inizio della copia e rimosso solo se termina bene. Vive dentro la
cartella dello snapshot, quindi la marcatura sopravvive alla fine dello script:
e' la memoria che le esecuzioni successive leggono per sapere cosa conservare e
cosa buttare (sezione 9). Contiene data, codice robocopy e nome del log
dettagliato. Dopo una copia con errori lo snapshot marcato viene eliminato
subito, quindi lo si trova su disco solo se la copia e' stata interrotta oppure
se non esiste nessuna copia completa.

Nota: alcune radici di volume hanno gli attributi Nascosto e Sistema e robocopy
puo' propagarli alla cartella di destinazione, che in Esplora risorse apparirebbe
vuota pur contenendo i dati (sono visibili da PowerShell con Get-ChildItem
-Force). Per questo l'engine riporta automaticamente la cartella del giorno e
quella dello snapshot a directory normale dopo ogni copia.

## 9. Retention

Dopo ogni copia, l'engine legge la data di ogni cartella con nome `AAAA-MM-GG`
sotto `$BackupRoot` e conserva gli ultimi `$RetainDays` giorni solari, **oggi
incluso**; le cartelle piu' vecchie vengono eliminate. Si tratta di una finestra
a calendario: i giorni senza backup non spostano la soglia, quindi eventuali
buchi sono gestiti correttamente. Il giorno corrente non viene mai eliminato:
se `$RetainDays` fosse impostato sotto 1, l'engine lo riporta a 1.

Esempio con `$RetainDays = 1` e data odierna 2026-09-03: resta solo la cartella
2026-09-03; vengono eliminate la 2026-09-02 e tutte le precedenti.

### Ultima copia

Dopo la finestra a calendario si applica la retention per snapshot: restano solo
gli ultimi `$RetainSnapshots` snapshot completi, anche dentro la cartella-giorno
corrente. Con il valore corrente (1) sul disco resta sempre e solo l'ultima copia
completa: il backup del pomeriggio, se riesce, elimina quello del mattino; se ha
errori, viene eliminato lui e resta quello del mattino.

Esempio: alle 12:00 viene creato `2026-09-03\12-00-00`; alle 17:40 la copia
riesce e crea `2026-09-03\17-40-00`, poi elimina `12-00-00`. Se la copia delle
17:40 avesse avuto errori, sarebbe stata eliminata `17-40-00` e sarebbe rimasta
`12-00-00`, con il rapporto per rilanciare (sezione successiva).

La retention opera esclusivamente all'interno di `$BackupRoot`. La sorgente non
viene mai modificata ne' cancellata. Prima di ogni rimozione si verifica il
percorso assoluto: sono ammessi solo giorni e snapshot datati sotto la radice;
radice del volume, radice del backup, log e collegamenti negli antenati vengono
rifiutati. La rimozione usa robocopy con `/MIR /XJ` e controlla il codice di
uscita, poi elimina la directory solo se vuota. Un errore ferma la pulizia e
restituisce 105, senza registrare una cancellazione riuscita.

Un file aperto da un altro processo (antivirus, indicizzatore, editor) non viene
eliminato, ma robocopy lo segnala solo nel log (ERRORE 32) ed esce con un codice
di successo. Per questo dopo ogni passata si contano gli elementi rimasti e la
purga si ripete fino a tre volte, dopo 5, 15 e 30 secondi. Se il residuo
persiste, l'errore elenca i primi elementi rimasti e la cancellazione resta
registrata: il backup successivo la riprende da solo.

Si contano file **e** cartelle. Una `/MIR` che non riesce a togliere una sola
cartella lascia un albero senza file e non vuoto: guardando i soli file il
residuo risultava inesistente, la purga non si ripeteva e la rimozione finale,
che non e' ricorsiva, falliva con un laconico "La directory non e' vuota" che
non diceva quale. Ora il residuo viene riconosciuto e nominato come qualunque
altro.

Prima della copia e dopo la verifica, se esiste una copia completa da conservare,
si eliminano gli snapshot marcati incompleti, si riprendono le cancellazioni
pendenti e si rimuovono i giorni vuoti. Questo libera lo spazio dei residui
prima di creare un altro snapshot. La retention delle copie complete avviene
dopo la nuova copia. Senza copie complete, le copie parziali vengono conservate.

Ogni rimozione viene prima annotata in un file sotto `_logs\_pulizie-pendenti`,
fuori dall'albero da cancellare, e tolta dal registro solo quando la directory
non esiste piu'. Ogni operazione ha il proprio file: aggiornare un record non
riscrive gli altri. Un'interruzione puo' eliminare il marcatore interno prima dei dati:
il registro evita che il residuo venga scambiato per una copia completa. Una
cartella ancora danneggiata puo' essere eliminata solo dopo la riparazione del
volume, che resta manuale. Cartelle estranee agli snapshot non vengono ripulite.

### Copie incomplete

Robocopy puo' arrivare in fondo e restituire un codice >= 8 perche' alcuni file
non sono stati copiati (file bloccati da un processo, errori di I/O, spazio
esaurito, permessi). Una copia cosi' non e' affidabile e non deve sostituire
l'ultima copia completa. Per questo l'engine tiene traccia dell'esito:

1. **Marcatura.** All'avvio della copia nella cartella dello snapshot viene
   scritto `_SNAPSHOT-INCOMPLETO.txt`, che viene tolto solo se il codice e' < 8,
   il conteggio dell'intero snapshot riesce e il volume resta sano.
   Se il codice e' >= 8 il file viene riscritto con codice e log; se lo script
   viene interrotto il file resta com'e'.
2. **Finestra allargata.** Nella stessa esecuzione la finestra di retention si
   estende fino a comprendere il giorno dell'ultimo snapshot **completo**, che
   quindi non viene cancellato anche se e' di un giorno precedente.
3. **Scarto della copia difettosa.** Se esiste una copia completa, lo snapshot
   appena creato con errori viene eliminato subito: sul disco resta solo l'ultima
   copia completa. Lo scarto viene registrato nello storico con esito `SCARTATO`.
4. **Rapporto per il rilancio.** In `_logs\BACKUP-FALLITO-RILANCIARE.txt` viene
   scritto un rapporto verboso, stampato anche a video: data, codice robocopy e
   suo significato, spazio libero sul disco di backup, esito (cosa e' stato
   eliminato e quale copia completa resta), elenco degli errori distinti trovati
   nel log robocopy (fino a 40, con la descrizione, per esempio "file utilizzato
   da un altro processo") e i comandi esatti per rilanciare subito, con e senza
   pop-up. Il pop-up di esito offre di aprire il rapporto nel Blocco note. Il
   rapporto viene sovrascritto a ogni nuovo fallimento ed eliminato dal primo
   backup riuscito: se il file esiste, il backup va rilanciato.
5. **Pulizia al primo backup completo.** Appena una copia riesce, tutti gli
   snapshot marcati rimasti (copie interrotte, oppure copie difettose conservate
   perche' non c'era nessuna copia completa) vengono eliminati, compresi quelli
   nella cartella-giorno corrente. La cancellazione viene registrata nello
   storico con esito `PULIZIA` e le cartelle-giorno rimaste vuote vengono rimosse.

Unica eccezione: se sul disco non esiste nessuna copia completa, lo snapshot
difettoso viene conservato (insieme al precedente, che puo' contenere i file
mancati stavolta), perche' una copia parziale e' meglio di nessuna copia. Il
rapporto lo segnala.

Il risultato e' che, dopo ogni esecuzione conclusa correttamente, sul disco resta sempre e solo
l'ultima copia completa e che una copia completa non viene mai sostituita da una
difettosa.

Esempio: il backup del 2026-09-03 alle 17:40 termina con codice 8 perche' un file
e' aperto in un IDE. `2026-09-03\17-40-00` viene eliminato, resta
`2026-09-03\12-00-00` e viene scritto il rapporto. Chiuso l'IDE, si lancia il
comando indicato nel rapporto: la nuova copia riesce, sostituisce `12-00-00` e il
rapporto sparisce.

### Errori benigni: il file sparito durante la copia

Non ogni codice >= 8 e' una perdita. Robocopy enumera l'albero all'inizio e
copia dopo: un file effimero creato e cancellato da un altro processo mentre la
copia e' in corso risulta "non copiato" con **ERRORE 2** (file non trovato) o
**ERRORE 3** (percorso non trovato), pur non essendo mai stato un dato da
salvare. Lo snapshot resta fedele alla sorgente di fine copia.

Prima di decidere, l'engine rilegge il proprio log robocopy e classifica ogni
errore distinto. Un errore e' **benigno** se, e solo se, valgono tutte queste
condizioni:

- il numero e' 2 o 3;
- il percorso si trova **dentro** la sorgente;
- quel percorso risulta **assente anche adesso**, a copia finita.

Se *tutti* gli errori del log sono benigni, il bit 8 viene tolto dal codice e lo
snapshot e' trattato come completo: niente marcatura, niente scarto, niente
rapporto di fallimento. Il declassamento viene annotato nello storico su una riga
propria con esito `EFFIMERI`, mentre la riga dello snapshot resta `| OK |`.

Basta una sola eccezione e il declassamento non avviene: un errore 5 (accesso
negato), 32 (file in uso), 112 (disco pieno), un percorso fuori dalla sorgente,
un percorso ricomparso, o il bit 16 (errore grave di robocopy). In quel caso lo
snapshot resta difettoso e segue la procedura descritta sopra.

Il motivo e' misurato. Il 2026-10-19 la copia delle 16:50 ha portato a termine
168.252 file su 168.253: l'unico mancante era
`...\_notes\tmp\guardia-modelli\.claude\templates\prova.md`, cancellato alle
17:07 e cercato da robocopy alle 17:10. Il codice 11 ha fatto scartare 25,6 GB
di copia buona, lasciando come unica copia quella del 2026-10-16. Lo stesso
incidente, in altra forma, era gia' costato due esclusioni tampone
(`COMMIT-MSG*.txt` il 2026-10-05, `E:\sync-dev\_logs` il 2026-10-16): il
declassamento lo risolve alla radice, senza togliere dati dal backup.

### La seconda passata: il guasto che robocopy conta e non racconta

Il declassamento descritto sopra sa decidere solo se il log porta righe di
errore. Robocopy pero' puo' contare un guasto nel riepilogo finale e non
scriverne niente.

Il 2026-10-28 la copia delle 11:30 e' uscita con codice 11. Nel riepilogo:
20.945 directory esaminate, **1 non riuscita**; 195.088 file, **0 non
riusciti**; 0 byte falliti. Nel log, nessuna riga `ERRORE`. Il declassamento non
ha trovato niente da declassare, lo snapshot e' stato dichiarato difettoso ed
eliminato, e il rapporto di fallimento ha annunciato "errori distinti nel log:
0" consigliando di controllare il codice 16, che non c'entrava. Risultato: 28,9
GB copiati bene buttati per una cartella di cui non si sapra' mai il nome, e il
backup tornato all'ultima copia del giorno prima.

Invece di indovinare, adesso si riprova. Se il codice ha il bit 8 ma non il bit
16, e `$RetryCopyOnFailure` e' attivo, l'engine fa una **seconda passata** con
gli stessi argomenti sullo stesso snapshot: `/E` e mai `/MIR`, quindi ricopia
cio' che manca e non cancella niente. Costa un'altra enumerazione della
sorgente, e solo quando la copia e' gia' andata male.

- Se la seconda passata torna con codice < 8, lo snapshot e' completo **per
  constatazione** e non per deduzione: robocopy ha appena riguardato tutto e non
  ha trovato piu' niente da fare. Il bit 8 viene tolto.
- Se fallisce ma i soli errori rimasti sono percorsi spariti dalla sorgente,
  vale la stessa clemenza della prima passata.
- Se fallisce davvero, il guasto e' reale e lo snapshot segue la procedura di
  sempre, con il rapporto di fallimento che ora cita entrambi i log.

Prima della seconda passata si ricontrolla il volume: su un disco che nel
frattempo si e' degradato non si scrive, e la ripresa viene saltata.

La ripresa serve anche ai guasti transitori che una riga di errore ce l'hanno,
per esempio il file tenuto aperto un istante dall'antivirus: `/R:1` e' una rete
a maglie larghe, una passata intera e' il tentativo serio. In entrambi i casi
l'esito viene annotato nello storico su una riga `RIPRESA` e il log della
seconda passata resta accanto al primo.

Il riepilogo di robocopy viene letto **per posizione** e non per etichetta: la
tabella e' tradotta nella lingua di Windows (`Directory`/`File` in italiano,
`Dirs`/`Files` in inglese), ma le sei colonne di interi sono sempre le stesse e
solo quelle due righe le hanno tutte intere. La quinta colonna e' "Non
riuscita". Cosi' il rapporto di fallimento, quando il log non spiega niente,
puo' almeno dire quante directory e quanti file robocopy ha contato come non
riusciti, invece di affermare che non e' successo niente.

## 10. Logging

Due log distinti in `_logs`:

- `storico-snapshot.txt`: log cumulativo in append, una riga per snapshot, senza
  retention. Registra data e ora, percorso relativo dello snapshot, esito e
  numero di file con dimensione totale. Registra anche i tentativi bloccati per
  sorgente assente, con esito `SCARTATO` gli snapshot difettosi eliminati
  subito, con esito `PULIZIA` gli snapshot incompleti eliminati in seguito e con
  esito `EFFIMERI` le copie promosse a complete perche' gli unici errori
  riguardavano file spariti durante la copia, e con esito `RIPRESA` l'esito
  della seconda passata quando la prima e' uscita con errori (sezione 9).
  Esempio:

  ```
  2026-06-09 12:31:04 | 2026-06-09\12-31-04 | OK | 12483 file | 3250,4 MB
  2026-06-09 17:50:12 | 2026-06-09\17-50-12 | ERRORI (codice 8) -> vedi backup_20260609_175012.log | 12102 file | 3120,7 MB
  2026-06-09 17:50:12 | SCARTATO | 2026-06-09\17-50-12 | snapshot difettoso eliminato, resta 2026-06-09\12-31-04 -> vedi BACKUP-FALLITO-RILANCIARE.txt
  2026-06-09 18:05:40 | 2026-06-09\18-05-40 | OK | 12495 file | 3252,0 MB
  2026-06-10 12:30:02 | 2026-06-10\12-30-02 | OK | 12502 file | 3253,1 MB
  2026-06-10 12:30:02 | EFFIMERI | 2026-06-10\12-30-02 | codice robocopy 11 declassato a 3: 1 percorsi spariti durante la copia e assenti anche in origine
  2026-06-11 11:30:05 | 2026-06-11\11-30-05 | OK | 12540 file | 3261,8 MB
  2026-06-11 11:30:05 | RIPRESA | 2026-06-11\11-30-05 | codice robocopy 11 declassato a 3: niente piu' da copiare -> vedi backup_20260611_113005_ripresa.log
  ```

- `backup_AAAAMMGG_HHMMSS.log`: log dettagliato di robocopy per ogni esecuzione,
  utile per il troubleshooting. Segue la stessa soglia a calendario delle
  cartelle-giorno, quindi restano i log degli ultimi `$RetainDays` giorni: con
  il valore corrente (1) restano solo quelli del giorno in corso. Il
  conteggio di file e dimensione nello storico e' calcolato in modo indipendente
  dalla lingua del sistema operativo.

- `backup_AAAAMMGG_HHMMSS_ripresa.log`: log della seconda passata, quando c'e'
  stata. Porta la stessa data e ora del log della prima, cosi' i due restano
  accanto, e segue la stessa retention.

- `BACKUP-FALLITO-RILANCIARE.txt`: rapporto dell'ultima copia con errori, con i
  file non copiati e i comandi per rilanciare (sezione 9). Se la seconda passata
  e' stata tentata, il rapporto cita anche il suo log e il suo codice, e gli
  errori elencati sono quelli rimasti dopo di essa. Esiste solo finche' un
  backup non riesce.

- `_pulizie-pendenti\`: memoria dei giorni o snapshot in eliminazione, con un
  file per operazione e soli percorsi relativi validati. Resta fino al recupero
  dei residui; un record illeggibile blocca la pulizia.

Sul disco locale, nella cartella `_logs` accanto agli script, si trova anche
`BACKUP-ERRORE.txt`: dettaglio cumulativo dei blocchi del volume e degli errori
di verifica o pulizia. Rimane consultabile se il disco esterno sparisce; e'
escluso da git insieme agli altri log. Una riga `OK` nello storico descrive lo
snapshot copiato e contato; il successo dell'intera esecuzione richiede anche
la pulizia e viene comunicato solo con codice 0 e il messaggio finale.

## 11. Verifica

Regressioni automatiche, senza avviare un backup reale:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\sync-dev\Test-Sicurezza.ps1
```

Il test crea un albero temporaneo isolato e controlla volumi degradati,
errori di conteggio, errori e ripresa della pulizia, protezione della sorgente,
confini dei percorsi, collegamenti e alberi oltre 260 caratteri. I processi
dell'engine usano solo configurazioni locali temporanee e una copia simulata.

1. Con il disco di backup corretto collegato e con la lettera attesa, eseguire:

   ```powershell
   powershell -ExecutionPolicy Bypass -File E:\sync-dev\Backup-Conferma.ps1
   ```

   Confermare e verificare la creazione di `J:\backup-sviluppo\<data>\<ora>`, di
   una riga in `storico-snapshot.txt` e di un file `backup_*.log`.
2. Collegare un disco diverso con la stessa lettera (o nessun disco): premendo
   Si deve comparire l'alert di blocco, senza copia.
3. Rendere non disponibile la sorgente (per esempio puntando `$Source` a un
   percorso inesistente in fase di test): premendo Si deve comparire l'alert
   sorgente, senza copia.
4. Premere No o lasciare scadere il timeout: non deve accadere nulla.
5. Per la retention, creare a mano alcune cartelle `AAAA-MM-GG` con date vecchie
   ed eseguire una copia valida: con `$RetainDays = 1` resta solo la cartella di
   oggi, tutte le precedenti vengono eliminate insieme ai loro `backup_*.log`,
   lo storico resta intatto.
   Eseguendo una seconda copia valida nello stesso giorno deve restare solo lo
   snapshot appena creato.
6. Per lo scarto delle copie con errori, tenere aperto in modo esclusivo un file
   della sorgente durante una copia (per esempio da PowerShell con
   `[System.IO.File]::Open('<file>', 'Open', 'Read', 'None')`). Lo snapshot appena
   creato deve essere eliminato, deve restare solo l'ultima copia completa, nello
   storico deve comparire una riga `SCARTATO` e in `_logs` deve comparire
   `BACKUP-FALLITO-RILANCIARE.txt` con il file bloccato tra gli errori. Chiuso il
   file e rilanciato il comando del rapporto, la nuova copia deve sostituire la
   precedente e il rapporto deve sparire.
7. Per la gestione delle copie incomplete, simulare uno snapshot difettoso: in
   una cartella-giorno vecchia creare `AAAA-MM-GG\HH-mm-ss` con dentro un file
   `_SNAPSHOT-INCOMPLETO.txt`, poi eseguire una copia valida. Lo snapshot marcato
   deve essere eliminato, nello storico deve comparire una riga `PULIZIA` e la
   cartella-giorno rimasta vuota deve sparire. Lo stesso vale per uno snapshot
   marcato creato dentro la cartella-giorno di oggi.
8. Nell'Utilita' di pianificazione, avviare manualmente il task: deve comparire
   il pop-up.

## 12. Ripristino

Ogni snapshot e' una copia navigabile uno a uno. Per ripristinare, individuare
la cartella `AAAA-MM-GG\HH-mm-ss` desiderata e copiare i file verso la sorgente,
manualmente o con robocopy invertendo sorgente e destinazione, senza opzioni di
purge o mirror.

## 13. Manutenzione

- Disattivare temporaneamente: nell'Utilita' di pianificazione, disabilitare il
  task.
- Cambiare modello di SSD, sorgente, orari o retention: aggiornare
  `Config-sync-dev.ps1` (e gli orari in `Registra-Task-Conferma.ps1`); per gli
  orari, rieseguire quest'ultimo (il parametro `-Force` sovrascrive il task).
- Rimuovere completamente:

  ```powershell
  Unregister-ScheduledTask -TaskName 'Backup Sviluppo (con conferma)' -Confirm:$false
  ```

- Permessi: se alcuni file non vengono copiati, impostare `-RunLevel Highest` in
  `Registra-Task-Conferma.ps1` e rieseguire lo script.

### Corruzione o espulsione negata del disco esterno

L'episodio diagnosticato il 2026-10-09 mostrava un volume exFAT con stato
`Warning / Full Repair Needed`. Nei registri Windows del 5 e 6 ottobre erano
presenti errori di scrittura del Samsung T7 e rimozioni improvvise nel registro
`Microsoft-Windows-Storage-Storport/Operational` (evento 551). Il 6 ottobre
alle 18:05:20 seguiva un nuovo tentativo di I/O (disk, 153), alle 18:05:34
una scrittura rimandata fallita con perdita di dati (exfat, 141). Gli eventi
Kernel-PnP 225 mostravano processi che impedivano l'espulsione, incluso l'engine
di backup. Questi dati documentano una connessione persa durante scritture;
non distinguono lo stacco manuale da un problema USB e non provano l'istante
in cui si e' danneggiata la specifica cartella dell'8 ottobre.

Con un volume degradato, chiudere i processi che lo usano e usare il controllo
errori di Windows. Da PowerShell amministratore la verifica senza riparazione
e' `chkdsk J:`; la riparazione richiesta manualmente e' `chkdsk J: /f` e agisce
sull'intero volume. `/scan` e' un'opzione per NTFS, non per questo volume exFAT.
Dopo la riparazione controllare `Get-Volume -DriveLetter J` e rilanciare il
backup: riprendera' i residui registrati. Attendere sempre la rimozione sicura
autorizzata da Windows. Se gli errori ritornano, verificare cavo, porta,
alimentazione e dispositivo, oltre alla procedura di espulsione.

Riferimenti Microsoft: [errori storage e corruzione](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/troubleshoot-data-corruption-and-disk-errors),
[chkdsk](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/chkdsk).

## 14. Limiti

- Gli snapshot sono copie multiple e indipendenti: piu' sicurezza nel ripristino
  di versioni recenti, maggiore occupazione di spazio.
- La soluzione e' una copia, non un sistema di versionamento dei file.
- Una copia con file mancanti non viene ritentata subito: l'engine la marca e
  protegge l'ultima copia completa (sezione 9), ma il recupero avviene alla
  successiva esecuzione confermata.
- Su un file system a cluster grandi lo snapshot occupa molto piu' della sua
  dimensione logica: su `J:`, exFAT con cluster da 128 KB, 26,1 GB logici ne
  occupano 46,6 reali. Il costo non dipende dai byte ma dal NUMERO di file, e la
  sorgente ne ha centinaia di migliaia di minuscoli. Una destinazione NTFS con
  cluster da 4 KB ridurrebbe lo snapshot di circa 21 GB senza escludere nulla:
  e' la singola leva piu' efficace, piu' di qualunque esclusione.
- Il disco di backup non e' dedicato: `J:` ospita anche archivi personali
  (circa 353 GB su 466), quindi al backup resta una frazione del volume. La
  guardia sullo spazio protegge dal riempimento, ma non crea spazio.
- Gli snapshot sono copie piene e indipendenti: su exFAT non esistono hard link,
  quindi non e' possibile un incrementale in stile Time Machine, dove ogni
  snapshot costa solo i file cambiati. Richiederebbe una destinazione NTFS.
- Da quando il progetto risiede in `E:\sync-dev` sta dentro la propria sorgente:
  si copia da solo negli snapshot (utile, il tool viaggia col backup) ma i suoi
  log vanno esclusi, perche' vengono scritti a copia in corso. Se `E:` si
  guastasse si perderebbero insieme i dati e gli script, che pero' restano su
  GitHub e dentro l'ultimo snapshot.
- Per protezione contro ransomware o guasti, valutare una terza copia offline
  periodica secondo la regola 3-2-1.
- Il pop-up appare solo a utente connesso, coerentemente con un disco di backup
  collegato solo in presenza dell'operatore.

## 15. Modalita' automatica (alternativa)

In alternativa alla conferma manuale esiste una modalita' automatica composta da
`Registra-Task.ps1` (esecuzione come SYSTEM agli orari previsti) e
`Watcher-Backup.ps1` (avvio della copia al collegamento del disco). Anche in
questa modalita' l'engine applica le verifiche di disco e sorgente, ma gli esiti
vengono solo registrati nei log, senza pop-up. Le due modalita' sono mutuamente
esclusive: utilizzarne una sola per evitare doppie esecuzioni.

## 16. Codici di uscita

L'engine `Backup-Sviluppo.ps1` comunica l'esito al chiamante con questi codici:

| Codice | Significato |
|--------|-------------|
| 0 | Operazione riuscita |
| 101 | Disco con la lettera attesa presente ma diverso dal dispositivo atteso |
| 102 | Sorgente non rilevata |
| 103 | Nessun disco con la lettera attesa collegato |
| 104 | Volume degradato o non verificabile: nessuna copia o pulizia avviata |
| 105 | Errore di I/O, verifica, log o pulizia: esecuzione non conclusa |
| 106 | Backup gia' in corso: nessuna nuova copia avviata |
| 107 | Spazio libero insufficiente: copia bloccata, nessuna scrittura sul disco |
| 108 | Il provider Storage di Windows non risponde entro il tetto di tempo: stato dei dischi non verificabile, nessuna scrittura |
| 8-16 | Errori riportati da robocopy (vedi log dettagliato) |

## 17. Controllo di versione e dati sensibili

Il repository contiene solo gli script, il README e il file `.gitignore`. I dati
di backup (i progetti) risiedono su un volume separato (`J:\backup-sviluppo`) e
non fanno parte del repository; il file `.gitignore` esclude comunque log, file
storici e cartelle datate, come rete di sicurezza.

Cosa controllare prima del primo commit:

- Nessuna credenziale o segreto. Gli script non contengono password, token o
  chiavi API. Il task viene registrato per l'utente corrente tramite variabili di
  ambiente risolte a runtime, quindi nessun nome utente o nome macchina viene
  scritto nei file.
- Il numero di serie del disco resta solo nell'override locale non tracciato:
  `$ExpectedDiskSerial = ''` nel `Config-sync-dev.ps1` versionato e
  `$ExpectedDiskSerial = '<SERIALE_DISCO>'` in `config.local.ps1` (escluso dal
  `.gitignore`). La configurazione carica automaticamente questo override.
  Credenziali e identificativi reali non vanno inseriti nei file tracciati.

Commit e push vengono eseguiti manualmente dall'utente, secondo le istruzioni
di macchina e del repository. L'agente prepara e verifica le modifiche ai file.

Sequenza per inizializzare il repository:

```powershell
cd E:\sync-dev
git init
git status            # verificare che vengano inclusi solo .ps1, README.md, .gitignore
git add .
git commit -m "sync-dev: backup locale con conferma, verifica disco e snapshot"
```

---
Documento anonimizzato: non contiene nomi utente, nomi macchina o riferimenti
personali o aziendali.
