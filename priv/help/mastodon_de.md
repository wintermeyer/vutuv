# Eine Mastodon-App benutzen

Sie können hier mit einer App lesen und schreiben, die für Mastodon gebaut wurde:
Ivory, Tusky, Ice Cubes, Mona, Elk und andere. Auf dem Telefon muss nichts weiter
installiert werden als die App selbst, und Sie behalten Ihr normales Konto. Die
App meldet sich daran an, so wie jede andere App, die Sie verbinden.

Das ist ausgeschaltet, bis Sie es einschalten.

## Einschalten

Öffnen Sie **Einstellungen → Apps & API** und schalten Sie *Mastodon-kompatible
Apps erlauben* ein. Vorher kann eine App die Anmeldung zwar abschließen, wird
danach aber bei jeder Anfrage abgewiesen. Das sieht nach einer kaputten App aus
und ist doch nur ein Schalter, den niemand umgelegt hat.

Wieder ausschalten wirkt sofort, auch für Apps, in denen Sie längst angemeldet
sind. An Ihrem Profil ändert sich so oder so nichts.

## Welche Adresse Sie eintippen

Wenn die App nach Ihrem Server fragt, tippen Sie:

```
{{host}}
```

Mehr nicht. Kein `https://`, keinen Pfad, kein `@` davor. Ihr Konto heißt dann
`@ihrbenutzername@{{host}}`, und das ist die Adresse für alle, die Ihnen von
einem anderen Server aus folgen wollen.

Die App öffnet daraufhin eine Browserseite hier, bittet Sie um Anmeldung, falls
Sie nicht schon angemeldet sind, und zeigt genau, was sie tun möchte. Wenn Sie
zustimmen, gibt der Browser Sie an die App zurück.

## Als Seite schreiben

Wenn Sie in der Redaktion einer Organisationsseite sind, bietet Ihnen der
Zustimmungsbildschirm diese Seite als zweite Identität an. Wählen Sie sie, gehört
alles, was die App schreibt, der Seite und nicht Ihnen, genau wie beim Wechsel
zur Seite auf der Website. Wer angemeldet war, wird intern weiter festgehalten,
das Team kann also immer nachvollziehen, wer was geschrieben hat.

Eine App, die als Seite angemeldet ist, kann niemanden blockieren: Blockieren ist
eine Sache zwischen zwei Menschen, und eine Seite ist keiner.

## Was funktioniert

* Ihr Feed, die öffentliche Zeitleiste dieser Installation und Hashtag-Zeitleisten
* Beiträge schreiben, ändern und löschen, auch mit Fotos
* Likes, Reposts, Lesezeichen und Antworten, mit denselben Zahlen wie auf der Website
* Benachrichtigungen, auch als Push-Nachricht bei geschlossener App
* Folgen, Entfolgen, Stummschalten und Blockieren, für Mitglieder, Seiten und
  Konten auf anderen Servern
* Die Suche nach Menschen, Beiträgen und Themen
* Ihre gespeicherten und gelikten Listen, Ihre Follower und wem Sie folgen

## Was hier anders ist

vutuv ist kein Mastodon-Server, deshalb tun ein paar Dinge, die eine App
anbietet, nicht das, was Sie erwarten:

* **Beiträge sind öffentlich.** Für die Zielgruppen-Auswahl der App gibt es hier
  keine Entsprechung. Wer einen Beitrag lesen darf, schränken Sie auf der Website
  ein, nicht in der App.
* **Keine Umfragen, keine eigenen Emojis, keine geplanten Beiträge.** Eine App,
  die das anbietet, bekommt eine leere Antwort.
* **Direktnachrichten sind keine Mastodon-Nachrichten.** Die Nachrichten von
  vutuv sind etwas Eigenes und bleiben auf der Website.
* **Folge-Anfragen gibt es nicht.** Wer hier folgt, folgt sofort.

## Wenn etwas nicht klappt

Prüfen Sie zuerst den Schalter, dann die Adresse. Daran liegt es fast immer. Wenn
eine App sich vor Monaten angemeldet hat und nicht mehr funktioniert, trennen Sie
sie unter **Einstellungen → Apps & API → Verbundene Apps** und melden sich neu
an.
