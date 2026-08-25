# Text formatieren mit Markdown

Überall dort, wo Sie auf vutuv längeren Text schreiben, verstehen wir Markdown:
in Beiträgen und Antworten, in Nachrichten, in den Beschreibungen Ihrer
Berufserfahrung und Ausbildung, in Stellenanzeigen und auf Organisationsseiten.
Markdown ist keine Programmiersprache, sondern eine Handvoll Zeichen, die man
sich in fünf Minuten merkt: zwei Sternchen für fett, ein Bindestrich für einen
Listenpunkt.

Im Beitragseditor müssen Sie das meiste davon gar nicht tippen. Er zeigt Ihnen
das Ergebnis direkt beim Schreiben und hat Schaltflächen für Fett, Kursiv,
Listen und den Rest. Wer lieber die Zeichen selbst schreibt, schaltet mit der
Schaltfläche **MD** in die Quelltextansicht. Diese Seite ist für beide Fälle
gedacht, und alles auf ihr ist echt: jedes Beispiel unten ist genau so
gerendert, wie es auch in Ihrem Beitrag aussehen wird.

## Fett, kursiv, durchgestrichen

| Sie schreiben | Sie sehen |
| --- | --- |
| `**wichtig**` | **wichtig** |
| `*betont*` | *betont* |
| `***beides***` | ***beides*** |
| `~~verworfen~~` | ~~verworfen~~ |
| `` `Codestück` `` | `Codestück` |

Ein Unterstrich tut dasselbe wie ein Sternchen: `_betont_` und `__wichtig__`
funktionieren ebenfalls. Wenn ein Sternchen einmal wirklich ein Sternchen sein
soll, stellen Sie einen Backslash davor: `\*so\*` erscheint als \*so\*.

## Absätze und Zeilenumbrüche

Eine Leerzeile beginnt einen neuen Absatz. Das ist der zuverlässigste Weg,
Text zu gliedern.

Ein einzelner Zeilenumbruch innerhalb eines Absatzes wird in einem **Beitrag**
nicht übernommen: der Text fließt weiter, so wie in einem Buch. Das ist Absicht,
denn sonst würde jeder Umbruch, den ein anderes Programm beim Kopieren
hineingeschrieben hat, im Beitrag als harter Umbruch stehenbleiben. In
**Nachrichten** ist es umgekehrt: dort bricht jede neue Zeile auch wirklich um,
weil man im Chat kurze Zeilen schreibt.

## Links, Erwähnungen und Hashtags

Eine Adresse, die mit `http://` oder `https://` beginnt, wird automatisch zum
Link. Sehr lange Adressen kürzen wir in der Anzeige, damit sie eine schmale
Spalte nicht sprengen; angeklickt führen sie natürlich vollständig ans Ziel.

Wenn Ihnen der Linktext wichtig ist, schreiben Sie ihn in eckige Klammern und
die Adresse dahinter in runde:

```markdown
[die Mitgliederliste](https://vutuv.de/system/members)
```

[die Mitgliederliste](https://vutuv.de/system/members)

Ein `@` vor einem Benutzernamen wird zur Verlinkung des Profils, sofern es
dieses Mitglied gibt. Fremde Namen bleiben einfacher Text, es entsteht also nie
ein Link ins Leere. Auf dieselbe Weise erreichen Sie Menschen im übrigen
Fediverse, wenn Sie den Server mit angeben: `@name@server.social` verlinkt
dorthin.

Ein `#` vor einem Wort wird zum Link auf die Themenseite dieses Tags, solange
das Tag auf vutuv überhaupt jemandem zugeordnet ist. `#elixir` führt also zu
den Mitgliedern, die Elixir können.

## Listen

Ein Bindestrich und ein Leerzeichen machen einen Aufzählungspunkt. Zwei
Leerzeichen Einrückung machen daraus eine Unterebene.

```markdown
- Bewerbungsgespräche
- Onboarding
  - Erste Woche
  - Erster Monat
```

- Bewerbungsgespräche
- Onboarding
  - Erste Woche
  - Erster Monat

Nummerierte Listen schreiben Sie mit Ziffer und Punkt:

```markdown
1. Stelle ausschreiben
2. Gespräche führen
3. Zusagen
```

1. Stelle ausschreiben
2. Gespräche führen
3. Zusagen

Ankreuzbare Kästchen (`- [ ]`) unterstützen wir nicht. Sie erscheinen als das,
was sie sind: eckige Klammern im Text.

## Überschriften

Ein bis sechs Rauten am Zeilenanfang, dann ein Leerzeichen:

```markdown
## Die Ausgangslage
### Ein Detail dazu
```

In Beiträgen erscheinen Überschriften als fetter Fließtext und nicht in
Schlagzeilengröße. Ein Beitrag ist kurz genug, dass eine große Überschrift ihn
optisch erschlagen würde. Die Gliederung bleibt trotzdem erhalten, für
Suchmaschinen und für Menschen, die den Beitrag vorgelesen bekommen.

## Zitate

Ein Größer-als-Zeichen am Zeilenanfang setzt den Text als Zitat ab:

```markdown
> Wir stellen zwei Entwicklerinnen ein.
```

> Wir stellen zwei Entwicklerinnen ein.

## Trennlinie

Drei Bindestriche allein auf einer Zeile ziehen eine waagerechte Linie:

```markdown
---
```

---

## Code

Einzelne Befehle, Dateinamen oder Feldnamen setzen Sie in einfache Backticks:
`` `mix test` `` wird zu `mix test`. Innerhalb solcher Backticks passiert nichts
weiter, ein `*` bleibt dort also ein `*`.

Längere Ausschnitte kommen zwischen zwei Zeilen mit je drei Backticks. Schreiben
Sie die Sprache direkt hinter die erste Zeile, dann steht ihr Name in der Ecke
des Blocks und der Code wird eingefärbt:

````markdown
```elixir
# Begrüßung
IO.puts("Hallo #{name}")
```
````

```elixir
# Begrüßung
IO.puts("Hallo #{name}")
```

Wir kennen rund 45 Sprachen, darunter Elixir, Erlang, Ruby, Python, PHP,
JavaScript, TypeScript, Go, Rust, Java, Kotlin, Swift, C, C++, C#, SQL, HTML,
CSS, YAML, JSON, Bash und Dockerfile. Eine Sprache, die wir nicht kennen,
schadet nichts: der Block bekommt trotzdem seine Beschriftung, nur eben keine
Farben. Soll ein Block gar keine Beschriftung tragen, schreiben Sie `text`
dahinter.

Das alles passiert auf unserem Server. Ihr Browser lädt für die Einfärbung
keine einzige Zeile zusätzlichen Code, und wer nie einen Codeblock zu Gesicht
bekommt, zahlt dafür auch nichts.

### Den Dateinamen dazuschreiben

Oft ergibt ein Ausschnitt erst Sinn, wenn man weiß, aus welcher Datei er stammt.
Schreiben Sie den Namen hinter einen Doppelpunkt:

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

Wer die ausführliche Schreibweise bevorzugt, schreibt stattdessen
`title="app/Providers/AppServiceProvider.php"`. Beide Formen ergeben denselben
Block. Nur wenn der Titel ein Leerzeichen enthält, brauchen Sie die
ausführliche Form.

### Änderungen zeigen

Die Sprache `diff` zeigt, was sich geändert hat. Zeilen mit einem `-` am Anfang
gelten als entfernt, Zeilen mit einem `+` als hinzugekommen:

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

Ein Diff sagt allerdings nichts darüber, in welcher Sprache der geänderte Code
geschrieben ist, deshalb blieb er bisher farblos. Nennen Sie die Sprache hinter
dem Doppelpunkt, und Sie bekommen beides: die Markierung der Änderung und die
Einfärbung des Codes.

````markdown
```diff:elixir
  def start(_type, _args) do
-   Logger.info("alt")
+   Logger.info("neu")
  end
```
````

```diff:elixir
  def start(_type, _args) do
-   Logger.info("alt")
+   Logger.info("neu")
  end
```

Ausführlich geschrieben ist das `lang="elixir"`. Ein Dateiname passt auch hier
noch dazu.

## Tabellen

Senkrechte Striche trennen die Spalten, die zweite Zeile aus Bindestrichen
trennt den Kopf vom Rest:

```markdown
| Rolle | Standort | offen seit |
| --- | --- | --- |
| Backend | Remote | März |
| Design | Hamburg | Mai |
```

| Rolle | Standort | offen seit |
| --- | --- | --- |
| Backend | Remote | März |
| Design | Hamburg | Mai |

Die Striche müssen nicht untereinander stehen. Ist eine Tabelle für den
Bildschirm zu breit, kann man sie seitlich schieben.

## Fußnoten

Eine Fußnote besteht aus zwei Teilen: der Marke im Text und der Anmerkung
darunter. Die Zahl dazwischen ist frei wählbar und muss nur zusammenpassen.

```markdown
Der Umsatz hat sich verdoppelt[^1].

[^1]: Gemessen am Vorjahresquartal.
```

Der Umsatz hat sich verdoppelt[^1].

[^1]: Gemessen am Vorjahresquartal.

Die Anmerkungen sammeln sich am Ende des Textes. Ein Klick auf die Marke
springt hinunter; zurück kommen Sie mit dem Zurück-Knopf Ihres Browsers oder
der Wischgeste Ihres Telefons.

## Bilder

Bilder gibt es nur in Beiträgen, und nur solche, die Sie selbst hochgeladen
haben. Der Weg dorthin führt über **Fotos hinzufügen** im Editor oder darüber,
dass Sie eine Bilddatei einfach in den Text ziehen. Ein Bild, das mitten im
Text steht, können Sie anschließend mit den kleinen Schaltflächen über dem
Editor nach links, nach rechts oder in die Mitte rücken; der Text fließt dann
darum herum.

Auf ein fremdes Bild im Netz zu verweisen, geht bewusst nicht. Jeder Aufruf
Ihres Beitrags würde sonst die IP-Adresse aller Leserinnen und Leser an einen
fremden Server melden.

## Was wir nicht rendern

HTML wird nicht ausgeführt, sondern angezeigt. Wer `<b>fett</b>` schreibt,
bekommt `<b>fett</b>` zu lesen. Das ist eine Sicherheitsentscheidung: würden
wir fremdes HTML ausführen, ließe sich damit Schadcode in die Seite anderer
Mitglieder schmuggeln.

Ebenfalls nicht dabei sind ankreuzbare Aufgabenlisten und eingebettete Videos
oder Karten. Ein Link auf das Video tut es auch.

## Und wenn etwas nicht klappt?

Schreiben Sie uns einen Beitrag mit `@vutuv` darin, oder melden Sie es als
[Fehler auf GitHub]({{issues}}). vutuv ist
quelloffen, und die Regeln auf dieser Seite stehen als Code im Repository.
