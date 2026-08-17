# Eine Mastodon-App benutzen

Du kannst hier mit einer App lesen und schreiben, die für Mastodon gebaut wurde
— Ivory, Tusky, Ice Cubes, Mona, Elk und andere. Auf dem Telefon muss nichts
weiter installiert werden als die App selbst, und du behältst dein normales
Konto: die App meldet sich daran an, so wie jede andere App, die du verbindest.

Das ist ausgeschaltet, bis du es einschaltest.

## Einschalten

Öffne **Einstellungen → Apps & API** und schalte *Mastodon-kompatible Apps
erlauben* ein. Vorher kann eine App die Anmeldung zwar abschließen, wird danach
aber bei jeder Anfrage abgewiesen — das sieht nach einer kaputten App aus und
ist doch nur ein Schalter, den niemand umgelegt hat.

Wieder ausschalten wirkt sofort, auch für Apps, in denen du längst angemeldet
bist. An deinem Profil ändert sich so oder so nichts.

## Welche Adresse du eintippst

Wenn die App nach deinem Server fragt, tippe:

```
{{host}}
```

Mehr nicht. Kein `https://`, keinen Pfad, kein `@` davor. Dein Konto heißt dann
`@deinbenutzername@{{host}}` — das ist die Adresse für alle, die dir von einem
anderen Server aus folgen wollen.

Die App öffnet daraufhin eine Browserseite hier, bittet dich um Anmeldung,
falls du nicht schon angemeldet bist, und zeigt genau, was sie tun möchte. Wenn
du zustimmst, gibt der Browser dich an die App zurück.

## Als Seite schreiben

Wenn du in der Redaktion einer Organisationsseite bist, bietet dir der
Zustimmungsbildschirm diese Seite als zweite Identität an. Wählst du sie, gehört
alles, was die App schreibt, der Seite und nicht dir — genau wie der Wechsel zur
Seite auf der Website. Wer angemeldet war, wird intern weiter festgehalten, das
Team kann also immer nachvollziehen, wer was geschrieben hat.

Eine App, die als Seite angemeldet ist, kann niemanden blockieren: Blockieren
ist eine Sache zwischen zwei Menschen, und eine Seite ist keiner.

## Was funktioniert

* Dein Feed, die öffentliche Zeitleiste dieser Installation und Hashtag-Zeitleisten
* Beiträge schreiben, ändern und löschen, auch mit Fotos
* Likes, Reposts, Lesezeichen und Antworten, mit denselben Zahlen wie auf der Website
* Benachrichtigungen, auch als Push-Nachricht bei geschlossener App
* Folgen, Entfolgen, Stummschalten und Blockieren — Mitglieder, Seiten und
  Konten auf anderen Servern
* Die Suche nach Menschen, Beiträgen und Themen
* Deine gespeicherten und gelikten Listen, deine Follower und wem du folgst

## Was hier anders ist

vutuv ist kein Mastodon-Server, deshalb tun ein paar Dinge, die eine App
anbietet, nicht das, was du erwartest:

* **Beiträge sind öffentlich.** Für die Zielgruppen-Auswahl der App gibt es hier
  keine Entsprechung — wer einen Beitrag lesen darf, schränkst du auf der
  Website ein, nicht in der App.
* **Keine Umfragen, keine eigenen Emojis, keine geplanten Beiträge.** Eine App,
  die das anbietet, bekommt eine leere Antwort.
* **Direktnachrichten sind keine Mastodon-Nachrichten.** Die Nachrichten von
  vutuv sind etwas Eigenes und bleiben auf der Website.
* **Folge-Anfragen gibt es nicht.** Wer hier folgt, folgt sofort.

## Wenn etwas nicht klappt

Prüfe zuerst den Schalter, dann die Adresse — daran liegt es fast immer. Wenn
eine App sich vor Monaten angemeldet hat und nicht mehr funktioniert, trenne sie
unter **Einstellungen → Apps & API → Verbundene Apps** und melde dich neu an.
