# Usare un'app Mastodon

Qui puoi leggere e scrivere da un'app pensata per Mastodon: Ivory, Tusky, Ice
Cubes, Mona, Elk e le altre. Sul tuo telefono non devi installare nulla oltre
all'app stessa, e mantieni il tuo account normale: l'app vi accede, come fa
qualsiasi altra app che colleghi.

Questa funzione è disattivata finché non la attivi tu.

## Come attivarla

Apri **Impostazioni → App e API** e attiva *Consenti le app compatibili con
Mastodon*. Finché non lo fai, un'app può portare a termine l'accesso e poi
vedersi rifiutare ogni richiesta successiva, il che sembra un'app rotta invece
che un interruttore che non hai ancora spostato.

Disattivarla ha effetto immediato, anche per le app da cui hai già effettuato
l'accesso. In nessuno dei due casi cambia qualcosa sul tuo profilo.

## L'indirizzo da digitare

Quando l'app ti chiede su quale server ti trovi, digita:

```
{{host}}
```

Nient'altro. Non aggiungere `https://`, né un percorso, né una `@`. Il tuo
account è allora `@iltuonomeutente@{{host}}`: è questo l'indirizzo da dare a
chi vuole seguirti da un altro server.

L'app aprirà qui una pagina del browser, ti chiederà di accedere se non lo hai
già fatto e ti mostrerà esattamente cosa intende fare. Approvala e il browser
ti riconsegnerà all'app.

## Scrivere come pagina

Se fai parte della redazione di una pagina di organizzazione, la schermata di
approvazione ti propone quella pagina come seconda identità. Scegli quella e
tutto ciò che l'app pubblica sarà della pagina, non tuo, esattamente come
quando passi alla pagina sul sito. Chi ha effettuato l'accesso resta comunque
registrato dietro le quinte, così il team può sempre sapere chi ha scritto
cosa.

Un'app collegata come pagina non può bloccare nessuno: il blocco è una cosa fra
due persone, e una pagina non è una persona.

## Cosa funziona

* Il tuo feed, la cronologia pubblica di questa installazione e le cronologie
  degli hashtag
* Scrivere, modificare ed eliminare post, foto comprese
* Mi piace, ricondivisioni, salvataggi e risposte, con gli stessi contatori che
  vedi sul sito
* Le notifiche, comprese quelle push mentre l'app è chiusa
* Seguire, smettere di seguire, silenziare e bloccare: membri, pagine e account
  su altri server
* Cercare persone, post e argomenti
* I tuoi elenchi di elementi salvati e piaciuti, i tuoi follower e chi segui

## Cosa qui è diverso

vutuv non è un server Mastodon, quindi alcune cose che un'app offre non faranno
quello che ti aspetti:

* **I post sono pubblici.** Il selettore del pubblico dell'app non ha un
  equivalente qui: chi può leggere un post lo restringi sul sito, non nell'app.
* **Niente sondaggi, niente emoji personalizzate, niente post programmati.**
  Un'app che li offre riceverà una risposta vuota.
* **I messaggi diretti non sono i messaggi di Mastodon.** I messaggi di vutuv
  sono una cosa a sé e restano sul sito.
* **Le richieste di follow non esistono.** Qui un follow ha effetto subito.

## Se qualcosa non funziona

Controlla prima l'interruttore, poi l'indirizzo: questi due spiegano quasi
tutti i problemi. Se un'app aveva effettuato l'accesso mesi fa e ha smesso di
funzionare, scollegala da **Impostazioni → App e API → App collegate** e accedi
di nuovo.
