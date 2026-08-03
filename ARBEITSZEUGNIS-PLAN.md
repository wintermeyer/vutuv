# Arbeitszeugnisse: Upload, Lebenslauf-Verknüpfung und KI-Prüfung

Arbeitsplan und Messdaten. Diese Datei ist ein Arbeitsdokument und wird am
Ende in `docs/architecture/job-references.md` überführt.

## 1. Was gebaut wird

Ein Mitglied lädt ein Arbeitszeugnis hoch, als PDF oder als eingefügter Text.
Es entscheidet, ob das Zeugnis öffentlich sichtbar ist (Vorgabe: **nein**),
verknüpft es mit einem oder mehreren Lebenslauf-Einträgen und kann es
anschließend von einem lokalen Sprachmodell prüfen lassen. Die Prüfung läuft
über eine Warteschlange; der Fortschritt erscheint ohne Neuladen im Browser.

Nicht-Ziele in dieser Ausbaustufe: kein Bearbeiten des Zeugnistextes im
Editor, kein Vergleich mehrerer Fassungen, kein Export der Prüfung als PDF.

## 2. Gemessene Grundlagen

Alle Zahlen stammen aus eigenen Läufen am 2026-08-02 gegen eine
Ollama-Instanz mit einer RTX A6000 (48 GB) und gegen eine reine CPU-Instanz
(32 Kerne). Sie begründen die Voreinstellungen weiter unten.

### 2.1 Der Prompt

| | Größe | Token | Befunde im Test |
|---|---|---|---|
| `SKILL.md` (Vollversion) | 131.302 Zeichen | **35.200** | 9 von 9 |
| `SKILL-mini.md` | 7.618 Zeichen | ~1.900 | 8 von 9 |

Wir nehmen die **Vollversion**. Die Mini-Fassung übersieht reproduzierbar die
Unterschriften-Formalie (`i. A.` durch eine nicht weisungsbefugte Person).

Ein dreiseitiges Zeugnis misst rund 2.600 Token, die Antwort 2.400 bis 3.700.
Gesamtbedarf also rund 42.000 Token.

### 2.2 Die stille Kontext-Falle

Der Server-Vorgabewert `OLLAMA_CONTEXT_LENGTH` ist häufig 32768. Der
Vollprompt passt dort **nicht** hinein, und Ollama meldet das nicht:

```
num_ctx=32768  ->  prompt_eval_count = 16.386  (von 35.559)
                   § 109 GewO: fehlt   Beweislast: fehlt
num_ctx=65536  ->  prompt_eval_count = 35.559
                   § 109 GewO: da      Beweislast: da
```

Der Prompt wird still halbiert, und das Modell liefert trotzdem eine
souverän formatierte Analyse mit Ampel, Note und fertigem Anschreiben, der
die halbe Rechtsgrundlage fehlt. Kein Fehler, keine Warnung.

**Folge für den Code:** `num_ctx` wird bei jeder Anfrage explizit gesetzt und
nie dem Server überlassen. Zusätzlich prüft der Client nach der Antwort, ob
`prompt_eval_count` mindestens der erwarteten Prompt-Größe entspricht, und
wertet eine Unterschreitung als Fehler statt als Ergebnis. Das ist die
Fail-closed-Regel: eine nicht beweisbare Vollständigkeit gilt als
unvollständig.

### 2.3 Laufzeiten

Warm, also mit dem Prompt-Präfix im KV-Cache:

| Modell | Prefill | Generierung | pro Zeugnis |
|---|---|---|---|
| `qwen3.6:27b` (dense) | 5,4 s | 24 tok/s | **146 s** |
| `qwen3.6:35b` (MoE) | 1,4 s | 85 tok/s | **45 s** |
| reine CPU, `qwen3.6:27b` | 28,2 tok/s | 4,65 tok/s | **~11 min** |

Kalt kostet der Prompt zusätzlich 75 s (dense) beziehungsweise 20 s (MoE).
Das Präfix ist über alle Anfragen identisch, der Cache greift also ab der
zweiten Prüfung.

Voreinstellung Modell: `qwen3.6:27b`. Der MoE ist viermal schneller, benennt
Noten aber unsauber ("Note 4 (befriedigend bis mangelhaft)"); ein früherer
Vergleich über 120 Stichproben ergab beim Deutschen ebenfalls einen Vorsprung
für das dichte Modell.

Beide Modelle benennen die Schulnoten falsch (Note 4 ist "ausreichend", nicht
"mangelhaft"). Das ist ein Modellfehler, den wir nicht wegkonfigurieren
können, und ein Grund für den Warnhinweis in der Ausgabe.

**Zeitüberschreitung:** 900 s als Vorgabe, damit auch eine CPU-Instanz mit
kaltem Modell durchläuft.

### 2.4 PDF nach Text

`pdftotext -layout` liest digitale PDFs verlustfrei, inklusive Umlauten,
§-Zeichen, Briefkopf und Aufzählungen. Geprüft an einer echten 14-seitigen
Testakte.

Bei einem Scan liefert `pdftotext` genau 1 Byte. Zwei Wege:

- **Tesseract 5.5 mit `deu`**: sichtbare Zeichenfehler, filterbar.
- **Vision-Modell** (`qwen3-vl:8b`): 99,4 % Wort-Recall in 38 s je Seite.
  Alle fünf notenrelevanten Formeln blieben exakt erhalten ("vollsten" /
  "vollen" / bloßes "Zufriedenheit", mit und ohne "stets"). Aber es machte
  aus "Kundenstammdaten" ein "Kundendaten".

Ein Sprachmodell verliest sich nicht, es **normalisiert plausibel**, und das
Ergebnis sieht aus wie korrekter Text. Bei einem Dokument, in dem ein
einzelnes Wort die Note trägt, ist der sichtbare Fehler der bessere.

**Folge für den Code:** Tesseract ist der Primärweg für Scans, das
Vision-Modell der Notnagel. Beides ist über Fähigkeitserkennung optional; ohne
beide bleibt der eingefügte Text der Weg. Jeder per OCR gewonnene Text wird
als solcher markiert, im Formular zur Korrektur angeboten und in der Ausgabe
mit einem Hinweis versehen.

## 2.5 Die Prüfung gilt nur für Deutschland

Der Skill prüft **deutsches** Zeugnisrecht: § 109 GewO, § 630 BGB, § 16 BBiG
und BAG-Rechtsprechung. Die Nachbarländer sind nicht eine Nuance daneben,
sondern ein anderes System. Österreich (§ 39 AngG) untersagt gerade die
codierte Benotung, die dieser Skill entschlüsselt; die Schweiz (Art. 330a OR)
hat eigene Formulierungspraxis und eigene Gerichtsentscheide. Ein deutsches
Ergebnis auf ein Schweizer Zeugnis wäre also nicht ungenau, sondern
zuversichtlich falsch.

Deshalb trägt jeder Eintrag ein **Land** (`country`, ISO 3166-1 alpha-2,
`NOT NULL`), vorbelegt aus `Vutuv.Geo.default_country/0`, also aus der
Einstellung der jeweiligen Installation.

- **Hochladen, verknüpfen, anzeigen** funktioniert in jedem Land.
- **Die Prüfung** wird nur für Länder in `:reference_check_countries`
  angeboten (Vorgabe `["DE"]`).

In der Oberfläche wird das ausgesprochen, nicht versteckt: Bei einem Eintrag
außerhalb der Liste steht anstelle des Knopfes der Grund, und das
Prüfergebnis selbst ist mit "Prüfung nach deutschem Zeugnisrecht" überschrieben.
Ein einfach fehlender Knopf läse sich als kaputte Funktion.

## 3. Datenmodell

Neuer Kontext `Vutuv.References`. Alle Schlüssel sind `Vutuv.UUIDv7`.

### 3.1 `job_references`

| Spalte | Typ | Anmerkung |
|---|---|---|
| `id` | binary_id | |
| `user_id` | binary_id | FK `users`, `on_delete: :delete_all` |
| `title` | varchar(255) | eigene Bezeichnung, `validate_length max: 255` |
| `employer` | varchar(255) | ausstellendes Unternehmen |
| `kind` | varchar(255) | `qualified` \| `simple` \| `interim` \| `apprenticeship` \| `service` |
| `issued_on` | date | Ausstellungsdatum, optional |
| `body` | text | der Zeugnistext, `validate_length max: 50_000` |
| `body_source` | varchar(255) | `typed` \| `pdf_text` \| `ocr_tesseract` \| `ocr_vision` |
| `public?` | boolean | **Vorgabe `false`** |
| `public_consented_at` | utc_datetime | gesetzt beim Anhaken |
| `document` | varchar(255) | Dateiname, nullable |
| `document_fingerprint` | varchar(255) | |
| `document_content_type` | varchar(255) | |
| `document_size` | integer | |
| `document_moderation` | varchar(255) | `pending` \| `approved` \| `rejected` |
| `document_page_count` | integer | |

`body` liegt bewusst in `text` mit großzügiger Obergrenze; 50.000 Zeichen sind
rund 13.500 Token und lassen im 65.536er Fenster reichlich Luft.

### 3.2 `job_reference_links`

Verknüpfung mit dem Lebenslauf. Drei nullbare Fremdschlüssel statt eines
polymorphen Paares, damit die referentielle Integrität in der Datenbank
bleibt:

| Spalte | Anmerkung |
|---|---|
| `job_reference_id` | FK, `on_delete: :delete_all` |
| `work_experience_id` | nullable, FK, `on_delete: :delete_all` |
| `education_id` | nullable, FK, `on_delete: :delete_all` |
| `qualification_id` | nullable, FK, `on_delete: :delete_all` |

Dazu eine `CHECK`-Bedingung, dass genau eine der drei Spalten gesetzt ist, und
je ein eindeutiger Index über `(job_reference_id, <spalte>)`.

### 3.3 `reference_checks`

Die Zeile **ist** der Auftrag, nach dem Muster von `Vutuv.Moderation.ImageScan`.

| Spalte | Anmerkung |
|---|---|
| `job_reference_id`, `user_id` | FK, `on_delete: :delete_all` |
| `status` | `pending` \| `running` \| `done` \| `failed` \| `canceled` |
| `attempts`, `next_attempt_at`, `last_error` | Wiederholungsleiter |
| `body_fingerprint` | bindet das Ergebnis an den geprüften Text |
| `skill_version`, `skill_sha256` | welcher Prompt es erzeugt hat |
| `model` | welches Modell |
| `result_markdown` | text, das Ergebnis |
| `prompt_tokens`, `output_tokens`, `duration_ms` | für die Anzeige und die Diagnose |
| `queued_at`, `started_at`, `finished_at` | |

Teilweise eindeutiger Index auf `job_reference_id WHERE status IN ('pending','running')`,
damit dieselbe Prüfung nie doppelt in der Schlange steht.

Ein `done`-Ergebnis, dessen `body_fingerprint` nicht mehr zum aktuellen Text
passt, wird als veraltet angezeigt, nicht gelöscht.

### 3.4 `reference_skill_versions`

Der täglich geholte Prompt, damit er einen Neustart überlebt und jede Prüfung
auf eine Zeile zeigen kann.

| Spalte | Anmerkung |
|---|---|
| `version` | aus dem `Version:`-Feld der Datei |
| `sha256` | Prüfsumme des Rumpfes |
| `body` | text |
| `source` | `remote` \| `vendored` |
| `fetched_at` | |

## 4. Module

| Modul | Aufgabe | Vorbild |
|---|---|---|
| `Vutuv.References` | Kontext: CRUD, Verknüpfungen, Sichtbarkeit | `Vutuv.Profiles` |
| `Vutuv.References.JobReference` | Schema samt Einwilligungs-Gate | `Profiles.Qualification` |
| `Vutuv.References.Link` | Verknüpfungs-Schema | neu |
| `Vutuv.References.Check` | Auftrags- und Ergebniszeile | `Moderation.ImageScan` |
| `Vutuv.References.Checks` | Warteschlange: einreihen, greifen, abarbeiten | `Moderation.ImageScans` |
| `Vutuv.References.CheckWorker` | GenServer, leert die Schlange | `Moderation.ImageScanWorker` |
| `Vutuv.References.Analyst` | Ollama-Client mit `num_ctx`-Gate | `Moderation.Ollama` |
| `Vutuv.References.Skill` | Prompt: holen, prüfen, zwischenspeichern | neu |
| `Vutuv.References.SkillRefresher` | GenServer, täglich | `Fediverse.CountsRefresher` |
| `Vutuv.References.TextExtraction` | PDF nach Text, OCR-Leiter | neu |
| `Vutuv.JobReferenceDocument` | Ablage, Vorschaubild | `Vutuv.QualificationDocument` |
| `VutuvWeb.JobReferenceController` | Verwaltung unter `/settings` | `QualificationController` |
| `VutuvWeb.JobReferenceDocumentController` | autorisierender Auslieferer | `QualificationDocumentController` |
| `VutuvWeb.ReferenceCheckLive` | Status und Ergebnis, live | `PostLive.Actions` |

## 5. Der Prompt als Quelle

`Vutuv.References.Skill.current/0` liefert `%{body, version, sha256, source}`.

- Quelle: `https://raw.githubusercontent.com/Klotzkette/arbeitszeugnispruefer-skill/refs/heads/main/skill/SKILL.md`
- Abruf einmal täglich durch `SkillRefresher`, mit `Req` (Projektregel).
- Schalter `:fetch_reference_skill` (Vorgabe `true`). Eine Installation ohne
  Internet schaltet ihn ab und bleibt bei der mitgelieferten Fassung.
- Mitgeliefert: `priv/reference_skill/SKILL.md`, damit die Prüfung ohne Netz
  funktioniert und ein erster Start nicht auf GitHub wartet.
- **Übernahme nur nach Prüfung**: Der Rumpf muss das Frontmatter
  `name: arbeitszeugnis-pruefer` und ein `Version:`-Feld tragen und mindestens
  50.000 Zeichen lang sein. Schlägt das fehl, bleibt die bisherige Fassung
  stehen und es wird geloggt. Fail closed, nie fail open.
- Jede Prüfung schreibt `skill_version` und `skill_sha256` mit, damit später
  nachvollziehbar ist, welcher Prompt ein Ergebnis erzeugt hat.

### Nennung der Quelle

Der Skill steht unter MIT beziehungsweise Apache-2.0, die Nennung ist also
Pflicht und ohnehin richtig. Jede Ausgabe trägt unter dem Ergebnis:

> Geprüft mit dem offenen Arbeitszeugnis-Prüfer-Skill (Version X.Y.Z) von
> [Klotzkette](https://github.com/Klotzkette/arbeitszeugnispruefer-skill),
> MIT/Apache-2.0. Analyse durch ein Sprachmodell auf unseren eigenen Servern.
> Keine Rechtsberatung.

Zusätzlich ein Abschnitt in `docs/architecture/job-references.md` und ein
Eintrag in `NOTICE`.

## 6. Sicherheit und Datenschutz

1. **Die Modellantwort ist unvertrauter Text.** Der Zeugnistext stammt vom
   Mitglied und geht in den Prompt; eine präparierte Datei kann das Modell zu
   HTML oder Skript verleiten. Die Ausgabe wird deshalb mit
   `VutuvWeb.Markdown.render/1` gerendert (maskiert `<`, Earmark,
   HtmlSanitizeEx), niemals mit `DevDocMarkdown`, der nur für vom Betreiber
   geschriebene Texte gedacht ist.
2. **Der Prompt bekommt eine Abgrenzung.** Der Zeugnistext wird in einer
   eigenen Nachricht mit klarer Markierung übergeben, verbunden mit der
   Anweisung, darin enthaltene Anweisungen als Zeugnisinhalt zu behandeln und
   nicht zu befolgen. Dasselbe Muster wie beim Bild-Prompt in
   `Vutuv.Moderation.Ollama`.
3. **Vorgabe ist nicht öffentlich.** `public?` steht auf `false`, das
   Anhaken ist ein hartes Changeset-Gate mit eigenem Einwilligungsfeld und
   Zeitstempel, wie bei den Qualifikationsnachweisen. Ohne Haken wird die
   Datei nicht öffentlich gestellt.
4. **Das hochgeladene PDF durchläuft die Bildmoderation** unter der neuen Art
   `job_reference_document`; solange sie läuft, sieht es nur der Eigentümer.
5. **Löschpfade**: Eintrag löschen, Dokument entfernen, Moderation lehnt ab,
   `Accounts.delete_user`. Alle vier müssen Datei, Vorschaubild, Original,
   Verknüpfungen und Prüfergebnisse mitnehmen.
6. **Ratenbegrenzung**: höchstens `:reference_checks_per_day` Prüfungen je
   Mitglied und Tag (Vorgabe 5). Eine Prüfung belegt die Instanz für Minuten.
7. **Der Zeugnistext ist besonders heikel**: Name, Geburtsdatum, Arbeitgeber
   und eine Leistungsbewertung. Er geht nur an die konfigurierte
   Ollama-Instanz, wird nicht protokolliert und erscheint in keiner
   Fehlermeldung.

### Datenschutzerklärung

Neuer Abschnitt: was hochgeladen wird, dass die Auswertung auf eigener
Infrastruktur ohne Weitergabe an Dritte läuft, wie lange gespeichert wird,
Vorgabe nicht öffentlich, und wie gelöscht wird.

Zwei Stellen, und die zweite geht nicht automatisch:

1. `priv/repo/seed_data/legal/datenschutzerklaerung.md` für neue
   Installationen.
2. Der Text im laufenden Betrieb ist eine **Datenbankzeile**, gepflegt unter
   `/admin/legal`. Der muss von Hand nachgezogen werden. Das gehört in die
   Beschreibung des Pull Requests, sonst geht es unter.

## 7. Konfiguration

Alles über Umgebungsvariablen, wie bei der Bildmoderation. Die Instanz wird
nicht im Code gewählt; `OLLAMA_URL` darf weiterhin eine nach Priorität
geordnete, kommagetrennte Liste sein.

| Schlüssel | Vorgabe | Zweck |
|---|---|---|
| `REFERENCE_CHECKS_ENABLED` | `true` | Funktion an oder aus |
| `REFERENCE_CHECK_MODEL` | `qwen3.6:27b` | Textmodell für die Prüfung |
| `REFERENCE_CHECK_NUM_CTX` | `65536` | **muss** den Prompt fassen, siehe 2.2 |
| `REFERENCE_CHECK_TIMEOUT` | `900000` | 15 Minuten, deckt eine CPU-Instanz |
| `REFERENCE_CHECKS_PER_DAY` | `5` | je Mitglied |
| `FETCH_REFERENCE_SKILL` | `true` | täglicher Abruf des Prompts |
| `REFERENCE_OCR` | `auto` | `auto` \| `tesseract` \| `vision` \| `off` |

`OLLAMA_URL` wird geteilt genutzt und nicht neu erfunden. Alle Schlüssel
kommen in die Tabelle in `docs/ADMINS.md`.

## 8. Oberfläche

### Verwaltung, `/settings/job_references`

Liste der eigenen Zeugnisse als Karten: Vorschaubild links, Titel und
Arbeitgeber, ein Merkmal für die Sichtbarkeit, die verknüpften
Lebenslauf-Einträge als Chips, der Zustand der Prüfung.

Formular in einem Schritt, nicht als Assistent:

1. Bezeichnung, Arbeitgeber, Art, Ausstellungsdatum
2. Der Text: Reiter "Datei hochladen" oder "Text einfügen". Nach dem Upload
   erscheint der gewonnene Text im Feld und bleibt bearbeitbar, mit Hinweis,
   falls er per OCR entstanden ist.
3. Verknüpfung mit dem Lebenslauf: Kästchen, gruppiert nach Berufserfahrung,
   Ausbildung und Qualifikation
4. Sichtbarkeit: aus, mit Erklärung und Schwärzungshinweis

### Öffentliche Ansicht

Auf dem Profil unter `/:slug/job_references` und als Beleg am verknüpften
Lebenslauf-Eintrag. Nur öffentliche Zeugnisse, nur mit freigegebener
Moderation.

**Projektregel:** Jede öffentliche Seite braucht ihre Geschwister in
`.md`, `.txt`, `.json` und `.xml` über `VutuvWeb.AgentDocs`, sonst schlägt
`agent_docs_drift_test.exs` fehl. Betrifft die Liste und die Einzelansicht.
Das Prüfergebnis gehört **nicht** dorthin: es ist immer privat.

### Die Prüfung, live

`VutuvWeb.ReferenceCheckLive`, per `live_render` eingebettet, Identität über
`VutuvWeb.Live.InitAssigns.session_user/1` (Projektregel, nie
`session["user_id"]`).

Zustände:

- noch nicht geprüft: Knopf "Zeugnis prüfen lassen" mit Hinweis auf die Dauer
- `pending`: "Position 2 in der Warteschlange"
- `running`: laufender Zähler, "Das dauert ein bis zwei Minuten"
- `done`: das Ergebnis, gerendert, mit Quellenangabe und Warnhinweis
- `failed`: verständlicher Text und ein Knopf zum Wiederholen
- veraltet: "Der Text wurde seit der Prüfung geändert"

Die Übergänge kommen über `Vutuv.Activity.broadcast/2` auf `"user:<id>"`, das
vorhandene Thema. Der Zähler läuft im Client, damit kein Timer je Sitzung
nötig ist.

Darstellung des Ergebnisses: Kopfzeile mit Gesamtnote und Ampelbilanz als
Kacheln, darunter die Abschnitte des Modells. Die Ampelzeichen (🔴 🟠 🟢) aus
der Antwort werden zu Farbmarken. Vorlage ist `.claude/rules/design.md`.

## 9. Reihenfolge der Arbeit

Jeder Schritt beginnt mit einem Test (Projektregel) und endet grün.

- [ ] **S1** Migrationen: die vier Tabellen, einzeln über
      `mix ecto.gen.migration` erzeugt, Datentypen gegen die Vorbildspalten
      geprüft
- [ ] **S2** `Vutuv.References.JobReference` samt Einwilligungs-Gate und
      Längenprüfungen; `Vutuv.References` mit CRUD und Sichtbarkeit
- [ ] **S3** `Vutuv.References.Link` und die Lebenslauf-Verknüpfung
- [ ] **S4** `Vutuv.JobReferenceDocument`: Ablage, Vorschaubild, Original,
      `pdftoppm`-Fähigkeitserkennung; `.gitignore` und
      `uploads_gitignore_test.exs` erweitern (Projektregel)
- [ ] **S5** `TextExtraction`: `pdftotext -layout`, dann Tesseract, dann
      Vision, jeweils fähigkeitserkannt
- [ ] **S6** `Skill`: mitgelieferte Fassung, Prüfung, Zwischenspeicher,
      `SkillRefresher`
- [ ] **S7** `Analyst`: Ollama-Client, `num_ctx` explizit, Vollständigkeits-
      prüfung der Prompt-Token, Abgrenzung gegen eingebettete Anweisungen
- [ ] **S8** `Check`, `Checks`, `CheckWorker`: Warteschlange, Wiederholungs-
      leiter, `resume_stuck`, `repair_drift`, PubSub
- [ ] **S9** Moderationsart `job_reference_document` samt aller vier
      Löschpfade
- [ ] **S10** Verwaltung: Controller, Formular, Vorlagen, Vorschaubild
- [ ] **S11** `ReferenceCheckLive` samt Ergebnisdarstellung
- [ ] **S12** Öffentliche Ansicht samt `AgentDocs`-Geschwistern
- [ ] **S13** Datenschutzerklärung, `docs/ADMINS.md`,
      `docs/architecture/job-references.md`, `NOTICE`, `README.md`
- [ ] **S14** `mix precommit` grün, Rauchtest im Browser, Versionsschub

## 10. Offene Entscheidungen

1. **Rechtlicher Zuschnitt.** Der Skill erzeugt von sich aus
   Berichtigungsverlangen, Klagestrategie und ein Vollstreckungsmodul für den
   Einzelfall. Das ist Rechtsdienstleistung im Sinne des RDG, und der Autor
   selbst führt EU-KI-Verordnung Anhang III (ausdrücklich
   Beschäftigungskontext), § 203 StGB und die DSGVO als ungeklärt auf. Eine
   reine Einordnung ohne Schriftsätze wäre deutlich unkritischer. Bis zur
   Entscheidung baue ich die Ausgabe **vollständig**, blende die
   Schriftsatz-Teile in der Oberfläche aber hinter einem Aufklapper mit
   Warnhinweis ein, sodass der Zuschnitt eine Anzeigeentscheidung bleibt und
   keine Umbauarbeit.
2. **Öffentliche Prüfergebnisse.** Vorerst nein, immer privat. Ein öffentlich
   sichtbares "Note 4" wäre ein Eigentor.

## 11. Abgeschlossen

Alle 14 Schritte sind erledigt. Nachträge zum Plan:

- **RDG-Zuschnitt** (Stefans Entscheidung): Die Schriftsätze fallen weg, die
  Einordnung bleibt. Der Schnitt sitzt in der **Anweisung** an das Modell, nicht
  in der Anzeige: ein Anschreiben, das nie entsteht, kann nicht gespeichert
  werden und nicht durch eine spätere Formatierungsänderung wieder auftauchen.
  `analyst_test.exs` hält die verbotene Liste fest.
- **Klarstellung** unter jedem Ergebnis, in dieser Reihenfolge: keine
  Rechtsberatung, wir prüfen den Fall nicht sondern den Wortlaut, Verweis auf
  einen Fachanwalt, dann die Quelle (frei verfügbarer Prompt von Klotzkette,
  MIT/Apache-2.0, mit Version) und der Satz, dass weder Prompt noch Modell von
  uns stammen.
- **Hub-Gruppe**: „Profil" war mit 8 Zeilen voll, also sind die Organisationen
  nach „Account" gewandert. `design.md` ist nachgezogen.
- **`:ollama_remote_timeout`** ist 30 s und passt zu einem Bild-Urteil, nicht zu
  einer Prüfung mit 75 s Prefill. `Vutuv.Ollama.post/3` nimmt jetzt ein eigenes
  `:remote_timeout`; jeder künftige langlaufende Ollama-Aufruf muss es setzen.
