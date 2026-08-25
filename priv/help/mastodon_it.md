# Usare un'app Mastodon

Qui può leggere e scrivere da un'app pensata per Mastodon: Ivory, Tusky, Ice
Cubes, Mona, Elk e le altre. Sul Suo telefono non deve installare nulla oltre
all'app stessa, e mantiene il Suo account normale: l'app vi accede, come fa
qualsiasi altra app che collega.

Questa funzione è disattivata finché non la attiva Lei.

## Come attivarla

Apra **Impostazioni → App e API** e attivi *Consenti le app compatibili con
Mastodon*. Finché non lo fa, un'app può portare a termine l'accesso e poi
vedersi rifiutare ogni richiesta successiva, il che sembra un'app rotta invece
che un interruttore che non ha ancora spostato.

Disattivarla ha effetto immediato, anche per le app da cui ha già effettuato
l'accesso. In nessuno dei due casi cambia qualcosa sul Suo profilo.

## L'indirizzo da digitare

Quando l'app Le chiede su quale server si trova, digiti:

```
{{host}}
```

Nient'altro. Non aggiunga `https://`, né un percorso, né una `@`. Il Suo
account è allora `@ilsuonomeutente@{{host}}`: è questo l'indirizzo da dare a
chi vuole seguirla da un altro server.

L'app aprirà qui una pagina del browser, Le chiederà di accedere se non lo ha
già fatto e Le mostrerà esattamente cosa intende fare. La approvi e il browser
La riconsegnerà all'app.

## Scrivere come pagina

Se fa parte della redazione di una pagina di organizzazione, la schermata di
approvazione Le propone quella pagina come seconda identità. La scelga e tutto
ciò che l'app pubblica sarà della pagina, non Suo, esattamente come quando
passa alla pagina sul sito. Chi ha effettuato l'accesso resta comunque
registrato dietro le quinte, così il team può sempre sapere chi ha scritto
cosa.

Un'app collegata come pagina non può bloccare nessuno: il blocco è una cosa fra
due persone, e una pagina non è una persona.

## Cosa funziona

* Il Suo feed, la cronologia pubblica di questa installazione e le cronologie
  degli hashtag
* Scrivere, modificare ed eliminare post, foto comprese
* Mi piace, ricondivisioni, salvataggi e risposte, con gli stessi contatori che
  vede sul sito
* Le notifiche, comprese quelle push mentre l'app è chiusa
* Seguire, smettere di seguire, silenziare e bloccare: membri, pagine e account
  su altri server
* Cercare persone, post e argomenti
* I Suoi elenchi di elementi salvati e piaciuti, i Suoi follower e chi segue

## Cosa qui è diverso

vutuv non è un server Mastodon, quindi alcune cose che un'app offre non faranno
quello che si aspetta:

* **I post sono pubblici.** Il selettore del pubblico dell'app non ha un
  equivalente qui: chi può leggere un post lo restringe sul sito, non nell'app.
* **Niente sondaggi, niente emoji personalizzate, niente post programmati.**
  Un'app che li offre riceverà una risposta vuota.
* **I messaggi diretti non sono i messaggi di Mastodon.** I messaggi di vutuv
  sono una cosa a sé e restano sul sito.
* **Le richieste di follow non esistono.** Qui un follow ha effetto subito.

## Se qualcosa non funziona

Controlli prima l'interruttore, poi l'indirizzo: questi due spiegano quasi
tutti i problemi. Se un'app aveva effettuato l'accesso mesi fa e ha smesso di
funzionare, la scolleghi da **Impostazioni → App e API → App collegate** e
acceda di nuovo.
