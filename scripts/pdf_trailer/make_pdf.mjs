// Draws the PDF the trailer attaches: a three-page programme for a fictional
// summer party, printed by Chrome so it looks like a real document.
//
//   node scripts/pdf_trailer/make_pdf.mjs <out.pdf>
import { chromium } from "playwright";

const out = process.argv[2];
const page = (title, body) => `<section class="page"><div class="band"></div><h1>${title}</h1>${body}
  <footer>Sommerfest 2026 · Werkstatt Neumann &amp; Partner</footer></section>`;

const html = `<!doctype html><html lang="de"><head><meta charset="utf-8"><style>
  @page { size: A4; margin: 0 }
  body { margin: 0; font-family: Georgia, serif; color: #1f2937 }
  .page { width: 210mm; height: 297mm; box-sizing: border-box; padding: 28mm 22mm; position: relative; page-break-after: always }
  .band { position: absolute; left: 0; top: 0; right: 0; height: 14mm; background: #1d4ed8 }
  h1 { font: 700 30pt/1.15 Georgia, serif; margin: 6mm 0 8mm; color: #111827 }
  h2 { font: 700 15pt/1.3 Georgia, serif; margin: 9mm 0 3mm; color: #1d4ed8 }
  p, li { font-size: 12pt; line-height: 1.55 }
  table { width: 100%; border-collapse: collapse; font-size: 12pt }
  td { padding: 3.2mm 0; border-bottom: 0.3mm solid #e5e7eb; vertical-align: top }
  td:first-child { width: 28mm; font-weight: 700; color: #1d4ed8 }
  footer { position: absolute; bottom: 14mm; left: 22mm; right: 22mm; font-size: 9pt; color: #6b7280; border-top: 0.3mm solid #e5e7eb; padding-top: 3mm }
  .lead { font-size: 14pt; color: #374151 }
</style></head><body>
${page("Sommerfest 2026", `<p class="lead">Samstag, 18. Juli, ab 14 Uhr im Hof der Werkstatt. Familien, Kolleginnen und Nachbarn sind herzlich eingeladen.</p>
  <h2>Programm</h2><table>
  <tr><td>14:00</td><td>Begrüßung und Kaffee</td></tr>
  <tr><td>15:00</td><td>Führung durch die neue Werkstatt</td></tr>
  <tr><td>16:30</td><td>Kinderprogramm mit Holzbau-Ecke</td></tr>
  <tr><td>18:00</td><td>Grill und Salatbuffet</td></tr>
  <tr><td>20:00</td><td>Live-Musik im Hof</td></tr></table>`)}
${page("Anfahrt &amp; Parken", `<h2>Mit dem Rad oder zu Fuß</h2><p>Der Hof liegt zehn Minuten vom Bahnhof entfernt. Fahrradständer stehen am Tor.</p>
  <h2>Mit dem Auto</h2><p>Parkplätze gibt es auf dem Gelände gegenüber. Bitte die Einfahrt der Nachbarn frei lassen.</p>
  <h2>Barrierefrei</h2><p>Alle Wege im Hof sind ebenerdig, eine Toilette ist rollstuhlgerecht.</p>`)}
${page("Mitbringen &amp; Anmelden", `<h2>Buffet</h2><p>Wer mag, bringt einen Salat oder einen Kuchen mit. Getränke und Grillgut stellen wir.</p>
  <h2>Anmeldung</h2><p>Bitte bis 10. Juli kurz Bescheid geben, mit wie vielen Personen ihr kommt.</p>
  <h2>Bei Regen</h2><p>Dann feiern wir in der großen Halle. Das Programm bleibt gleich.</p>`)}
</body></html>`;

const browser = await chromium.launch({ channel: "chrome" });
const p = await browser.newPage();
await p.setContent(html, { waitUntil: "load" });
await p.pdf({ path: out, format: "A4", printBackground: true, preferCSSPageSize: true });
await browser.close();
console.log("pdf", out);
