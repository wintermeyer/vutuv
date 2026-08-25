# Formattare il testo con Markdown

Ovunque su vutuv scriva più di una riga, noi capiamo il Markdown: nei post e
nelle risposte, nei messaggi, nelle descrizioni della Sua esperienza lavorativa
e della Sua formazione, negli annunci di lavoro e sulle pagine delle
organizzazioni. Markdown non è un linguaggio di programmazione, è una manciata
di caratteri che si imparano in cinque minuti: due asterischi per il grassetto,
un trattino per una voce di elenco.

Nell'editor dei post raramente deve digitarne qualcuno. Le mostra il risultato
mentre scrive e ha i pulsanti per grassetto, corsivo, elenchi e il resto. Se
preferisce digitare Lei i caratteri, il pulsante **MD** passa alla vista del
sorgente. Questa pagina è scritta per entrambi i tipi di autore, e tutto ciò
che contiene è reale: ogni esempio qui sotto è reso esattamente come apparirà
nel Suo post.

## Grassetto, corsivo, barrato

| Lei scrive | Ottiene |
| --- | --- |
| `**importante**` | **importante** |
| `*enfasi*` | *enfasi* |
| `***entrambi***` | ***entrambi*** |
| `~~eliminato~~` | ~~eliminato~~ |
| `` `un frammento` `` | `un frammento` |

Il trattino basso fa lo stesso lavoro dell'asterisco: funzionano anche
`_enfasi_` e `__importante__`. Quando un asterisco deve davvero essere un
asterisco, gli metta davanti una barra rovesciata: `\*così\*` esce come \*così\*.

## Paragrafi e ritorni a capo

Una riga vuota inizia un nuovo paragrafo. È il modo più affidabile per dare una
forma a un testo.

Un singolo ritorno a capo dentro un paragrafo *non* viene mantenuto in un
**post**: il testo prosegue, come in un libro. È voluto, perché altrimenti ogni
interruzione lasciata da un altro programma quando ha copiato il testo
comparirebbe come un'interruzione forzata nel Suo post. Nei **messaggi** vale
il contrario: lì ogni riga nuova va davvero a capo, perché in chat si scrive a
righe brevi.

## Link, menzioni e hashtag

Un indirizzo che inizia con `http://` o `https://` diventa un link da sé. Nella
visualizzazione accorciamo gli indirizzi molto lunghi, così non possono far
esplodere una colonna stretta; premendoci sopra si arriva comunque alla
destinazione completa.

Quando conta il testo del link, metta il testo fra parentesi quadre e
l'indirizzo fra parentesi tonde subito dopo:

```markdown
[l'elenco dei membri](https://vutuv.de/system/members)
```

[l'elenco dei membri](https://vutuv.de/system/members)

Una `@` davanti a un nome utente rimanda a quel profilo, purché il membro
esista. Un nome che non conosciamo resta testo semplice, così un link non
finisce mai nel vuoto. La stessa sintassi raggiunge le persone altrove nel
Fediverso se ne indica il server: `@nome@server.social` rimanda lì.

Un `#` davanti a una parola rimanda alla pagina di quel tag, purché il tag
appartenga a qualcuno su vutuv. Così `#elixir` porta il lettore ai membri che
conoscono Elixir.

## Elenchi

Un trattino e uno spazio fanno un punto elenco. Due spazi di rientro fanno un
sottolivello.

```markdown
- Colloqui
- Inserimento
  - Prima settimana
  - Primo mese
```

- Colloqui
- Inserimento
  - Prima settimana
  - Primo mese

Gli elenchi numerati vogliono una cifra e un punto:

```markdown
1. Pubblichi l'annuncio
2. Parli con le persone
3. Faccia una proposta
```

1. Pubblichi l'annuncio
2. Parli con le persone
3. Faccia una proposta

Gli elenchi con caselle di spunta (`- [ ]`) non sono supportati. Escono per
quello che sono: parentesi quadre nel testo.

## Titoli

Da uno a sei cancelletti all'inizio di una riga, poi uno spazio:

```markdown
## Da dove siamo partiti
### Un dettaglio in proposito
```

Nei post i titoli sono resi come testo in grassetto invece che a dimensione di
titolo. Un post è abbastanza breve che un titolo grande lo appiattirebbe
visivamente. La struttura resta comunque, per i motori di ricerca e per chi si
fa leggere il post ad alta voce.

## Citazioni

Un segno di maggiore all'inizio di una riga stacca il testo come citazione:

```markdown
> Stiamo assumendo due sviluppatori.
```

> Stiamo assumendo due sviluppatori.

## Linea orizzontale

Tre trattini da soli su una riga tracciano una linea:

```markdown
---
```

---

## Codice

Singoli comandi, nomi di file o nomi di campo vanno fra apici inversi
semplici: `` `mix test` `` diventa `mix test`. Dentro quegli apici non succede
nient'altro, quindi un `*` resta un `*`.

I frammenti più lunghi vanno fra due righe di tre apici inversi. Scriva il
linguaggio subito dopo la prima riga e il blocco riceve il suo nome nell'angolo
e il codice a colori:

````markdown
```elixir
# un saluto
IO.puts("Ciao #{nome}")
```
````

```elixir
# un saluto
IO.puts("Ciao #{nome}")
```

Conosciamo circa 45 linguaggi, fra cui Elixir, Erlang, Ruby, Python, PHP,
JavaScript, TypeScript, Go, Rust, Java, Kotlin, Swift, C, C++, C#, SQL, HTML,
CSS, YAML, JSON, Bash e Dockerfile. Un linguaggio che non conosciamo non fa
danni: il blocco riceve comunque la sua etichetta, semplicemente non riceve i
colori. Per non far portare al blocco alcuna etichetta, scriva `text` dopo gli
apici inversi.

Tutto questo avviene sul nostro server. Il Suo browser non scarica una sola
riga di codice in più per la colorazione, e un lettore che non vede mai un
blocco di codice non paga nulla per averla.

### Indicare il file

Spesso un frammento ha senso solo quando si sa da quale file viene. Scriva il
nome dopo i due punti:

````markdown
```php:app/Providers/AppServiceProvider.php
<?php
$a = 1;
```
````

```php:app/Providers/AppServiceProvider.php
<?php
$a = 1;
```

Se preferisce la forma lunga, scriva invece
`title="app/Providers/AppServiceProvider.php"`. Producono lo stesso blocco. La
forma lunga Le serve solo quando il titolo contiene uno spazio.

### Mostrare una modifica

Il linguaggio `diff` mostra cosa è cambiato. Le righe che iniziano con `-`
valgono come rimosse, quelle che iniziano con `+` come aggiunte:

````markdown
```diff
- $port = 4000
+ $port = 4001
```
````

```diff
- $port = 4000
+ $port = 4001
```

Un diff però non dice nulla sul linguaggio in cui è scritto il codice
modificato, ed è per questo che un tempo restava senza colori. Indichi il
linguaggio dopo i due punti e ottiene entrambe le cose: la modifica è
evidenziata e il codice è colorato.

````markdown
```diff:elixir
  def start(_type, _args) do
-   Logger.info("vecchio")
+   Logger.info("nuovo")
  end
```
````

```diff:elixir
  def start(_type, _args) do
-   Logger.info("vecchio")
+   Logger.info("nuovo")
  end
```

Scritto per esteso è `lang="elixir"`. Accanto ci sta comunque anche un nome di
file.

## Tabelle

Le barre verticali separano le colonne, la seconda riga di trattini separa
l'intestazione dal resto:

```markdown
| Ruolo | Luogo | Aperto da |
| --- | --- | --- |
| Backend | Da remoto | marzo |
| Design | Amburgo | maggio |
```

| Ruolo | Luogo | Aperto da |
| --- | --- | --- |
| Backend | Da remoto | marzo |
| Design | Amburgo | maggio |

Le barre non devono essere allineate. Una tabella troppo larga per lo schermo
si può far scorrere lateralmente.

## Note a piè di pagina

Una nota ha due parti: il segnalino nel testo e la nota sotto. Il numero fra i
due lo sceglie Lei, deve solo corrispondere.

```markdown
Il fatturato è raddoppiato[^1].

[^1]: Misurato sullo stesso trimestre dell'anno scorso.
```

Il fatturato è raddoppiato[^1].

[^1]: Misurato sullo stesso trimestre dell'anno scorso.

Le note si raccolgono alla fine del testo. Premendo un segnalino si salta alla
sua nota; il pulsante Indietro del browser, o il gesto Indietro del telefono,
La riporta subito dove stava leggendo.

## Immagini

Le immagini stanno solo nei post, e solo quelle che ha caricato Lei. La strada
è **Aggiungi immagini** nell'editor, oppure semplicemente trascinare un file di
immagine dentro il testo. Un'immagine che sta in mezzo al testo si può poi
spostare a sinistra, a destra o al centro con i pulsantini sopra l'editor, e il
testo le scorre attorno.

Puntare all'immagine di qualcun altro sul web non è possibile, ed è voluto:
altrimenti ogni visualizzazione del Suo post comunicherebbe l'indirizzo IP di
ogni lettore a un server che non è il nostro.

## Cosa non rendiamo

L'HTML viene mostrato, non eseguito. Scriva `<b>grassetto</b>` e i Suoi lettori
vedranno `<b>grassetto</b>`. È una decisione di sicurezza: se eseguissimo
l'HTML altrui, lo si potrebbe usare per introdurre codice ostile nella pagina
di un altro membro.

Mancano anche gli elenchi di attività con caselle di spunta e i video o le
mappe incorporati. Un link al video fa lo stesso servizio.

## Quando qualcosa non funziona

Scriva un post menzionando `@vutuv`, oppure lo segnali come
[bug su GitHub]({{issues}}). vutuv è open
source, e le regole di questa pagina sono codice nel repository.
