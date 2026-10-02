# sync-dev — istruzioni per l'agente

## Version control: sempre manuale

I comandi di version control su questo repository li esegue **l'utente**, mai l'agente.

Non eseguire `git add`, `git commit`, `git push`, `git reset`, `git checkout`,
`git merge`, `git rebase`, `git stash` ne' alcun altro comando che modifichi
l'indice, la history o il working tree tramite git. Non farlo nemmeno quando un
piano approvato include un passo di commit: l'approvazione del piano non e'
un'autorizzazione a usare git.

Al termine di una modifica: applica le modifiche ai file, verifica, riepiloga
cosa e' cambiato e **fermati**. Se un messaggio di commit puo' essere utile,
proponilo come testo da copiare, senza eseguirlo.

I comandi git in **sola lettura** (`git status`, `git log`, `git diff`,
`git show`, `git remote -v`) restano consentiti: servono a capire lo stato del
repository e non modificano nulla.

Unica eccezione: una richiesta esplicita dell'utente in quel momento, del tipo
"fai il commit" o "pusha". Vale solo per quella richiesta, non per quelle
successive.
