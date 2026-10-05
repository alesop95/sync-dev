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
- Snapshot datati con retention a finestra di giorni solari (oggi incluso) e
  sul numero di snapshot: resta solo l'ultima copia completa.
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
- Cartella degli script: `C:\Scripts\sync-dev`

## 2. Contenuto del repository

| File | Ruolo |
|------|-------|
| `Config-sync-dev.ps1` | Parametri e funzioni condivise (caricato dagli altri script) |
| `Backup-Sviluppo.ps1` | Verifica disco e sorgente, crea lo snapshot, scrive i log, marca le copie incomplete, applica la retention |
| `Backup-Conferma.ps1` | Mostra il pop-up; richiama l'engine e mostra esito o alert |
| `Registra-Task-Conferma.ps1` | Registra il task pianificato (una tantum) |
| `Mostra-Dischi.ps1` | Elenca i dischi collegati con lettera, modello, serial e bus |
| `Imposta-LetteraJ.ps1` | Assegna la lettera attesa al disco atteso |
| `README.md` | Questo documento |

File della modalita' automatica alternativa (non attivi, vedi sezione 15):

| File | Ruolo |
|------|-------|
| `Registra-Task.ps1` | Registra i task automatici (orari + watcher) |
| `Watcher-Backup.ps1` | Avvia la copia al collegamento del disco di backup |

Tutti gli script devono risiedere nella stessa cartella (`C:\Scripts\sync-dev`),
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
| `$ExcludeDirs` | vedi file | Cartelle escluse dalla copia (per nome, a ogni profondita') |
| `$ExcludeFiles` | vedi file | Pattern di file esclusi |

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
C:\Scripts\sync-dev\Mostra-Dischi.ps1
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
C:\Scripts\sync-dev\Imposta-LetteraJ.ps1
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

1. Copiare tutti gli script nella cartella `C:\Scripts\sync-dev`.
2. Aprire PowerShell come Amministratore (con il proprio account).
3. Sbloccare i file e abilitare l'esecuzione degli script locali (lo scope
   CurrentUser non richiede privilegi di amministratore):

   ```powershell
   Get-ChildItem C:\Scripts\sync-dev\*.ps1 | Unblock-File
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
   C:\Scripts\sync-dev\Mostra-Dischi.ps1
   ```

6. Assegnare la lettera attesa al disco (se non gia' impostata):

   ```powershell
   C:\Scripts\sync-dev\Imposta-LetteraJ.ps1
   ```

7. Registrare il task pianificato:

   ```powershell
   C:\Scripts\sync-dev\Registra-Task-Conferma.ps1
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
viene mai modificata ne' cancellata. La rimozione delle cartelle usa un metodo
robusto anche per alberi profondi.

### Copie incomplete

Robocopy puo' arrivare in fondo e restituire un codice >= 8 perche' alcuni file
non sono stati copiati (file bloccati da un processo, errori di I/O, spazio
esaurito, permessi). Una copia cosi' non e' affidabile e non deve sostituire
l'ultima copia completa. Per questo l'engine tiene traccia dell'esito:

1. **Marcatura.** All'avvio della copia nella cartella dello snapshot viene
   scritto `_SNAPSHOT-INCOMPLETO.txt`, che viene tolto solo se il codice e' < 8.
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

Il risultato e' che, dopo ogni esecuzione conclusa, sul disco resta sempre e solo
l'ultima copia completa e che una copia completa non viene mai sostituita da una
difettosa.

Esempio: il backup del 2026-09-03 alle 17:40 termina con codice 8 perche' un file
e' aperto in un IDE. `2026-09-03\17-40-00` viene eliminato, resta
`2026-09-03\12-00-00` e viene scritto il rapporto. Chiuso l'IDE, si lancia il
comando indicato nel rapporto: la nuova copia riesce, sostituisce `12-00-00` e il
rapporto sparisce.

## 10. Logging

Due log distinti in `_logs`:

- `storico-snapshot.txt`: log cumulativo in append, una riga per snapshot, senza
  retention. Registra data e ora, percorso relativo dello snapshot, esito e
  numero di file con dimensione totale. Registra anche i tentativi bloccati per
  sorgente assente, con esito `SCARTATO` gli snapshot difettosi eliminati
  subito e con esito `PULIZIA` gli snapshot incompleti eliminati in seguito
  (sezione 9). Esempio:

  ```
  2026-06-09 12:31:04 | 2026-06-09\12-31-04 | OK | 12483 file | 3250,4 MB
  2026-06-09 17:50:12 | 2026-06-09\17-50-12 | ERRORI (codice 8) -> vedi backup_20260609_175012.log | 12102 file | 3120,7 MB
  2026-06-09 17:50:12 | SCARTATO | 2026-06-09\17-50-12 | snapshot difettoso eliminato, resta 2026-06-09\12-31-04 -> vedi BACKUP-FALLITO-RILANCIARE.txt
  2026-06-09 18:05:40 | 2026-06-09\18-05-40 | OK | 12495 file | 3252,0 MB
  ```

- `backup_AAAAMMGG_HHMMSS.log`: log dettagliato di robocopy per ogni esecuzione,
  utile per il troubleshooting. Segue la stessa soglia a calendario delle
  cartelle-giorno, quindi restano i log degli ultimi `$RetainDays` giorni: con
  il valore corrente (1) restano solo quelli del giorno in corso. Il
  conteggio di file e dimensione nello storico e' calcolato in modo indipendente
  dalla lingua del sistema operativo.

- `BACKUP-FALLITO-RILANCIARE.txt`: rapporto dell'ultima copia con errori, con i
  file non copiati e i comandi per rilanciare (sezione 9). Esiste solo finche'
  un backup non riesce.

## 11. Verifica

1. Con il disco di backup corretto collegato e con la lettera attesa, eseguire:

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\Scripts\sync-dev\Backup-Conferma.ps1
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

## 14. Limiti

- Gli snapshot sono copie multiple e indipendenti: piu' sicurezza nel ripristino
  di versioni recenti, maggiore occupazione di spazio.
- La soluzione e' una copia, non un sistema di versionamento dei file.
- Una copia con file mancanti non viene ritentata subito: l'engine la marca e
  protegge l'ultima copia completa (sezione 9), ma il recupero avviene alla
  successiva esecuzione confermata.
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
| 8 o superiore | Errori riportati da robocopy (vedi log dettagliato) |

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
- Unico identificatore presente: il numero di serie del disco in
  `Config-sync-dev.ps1` (`$ExpectedDiskSerial`). Non e' una credenziale, e' un
  identificatore hardware, inutile senza accesso fisico al dispositivo. Per un
  repository privato puo' restare nel file tracciato senza problemi.
- Se si preferisce non versionare il numero di serie (per esempio se il
  repository potrebbe diventare pubblico), si puo' usare un override locale non
  tracciato: impostare `$ExpectedDiskSerial = ''` nel `Config-sync-dev.ps1`
  tracciato e creare un file `config.local.ps1` (gia' escluso dal `.gitignore`)
  con la riga `$ExpectedDiskSerial = '<serial reale>'`. Il file di configurazione
  carica automaticamente `config.local.ps1` se presente.

Sequenza per inizializzare il repository:

```powershell
cd C:\Scripts\sync-dev
git init
git status            # verificare che vengano inclusi solo .ps1, README.md, .gitignore
git add .
git commit -m "sync-dev: backup locale con conferma, verifica disco e snapshot"
```

---
Documento anonimizzato: non contiene nomi utente, nomi macchina o riferimenti
personali o aziendali.
