#!/bin/sh
# Produces the German PDF trailer, start to finish (~1 minute).
#
#   scripts/pdf_trailer/run.sh
#
# Result: _build/pdf_trailer/vutuv-pdf-trailer-de.mp4 (1920x1080, silent) and
# a poster PNG. A fictional member (Clara Neumann, seed.exs) writes a post,
# drops a PDF into the composer, posts it, and opens its pages in the lightbox.
# Needs poppler-utils (the file's preview pages) and Google Chrome.
set -eu
cd "$(dirname "$0")/../.."
OUT=_build/pdf_trailer
PORT=${TRAILER_PORT:-4078}
mkdir -p "$OUT"

[ -d scripts/pdf_trailer/node_modules ] || (cd scripts/pdf_trailer && npm install --silent)
[ -f "$OUT/logo_white_full.png" ] || cp priv/static/images/teaser/logo_white_full.png "$OUT/" 2>/dev/null ||
  { echo "put a white vutuv logo PNG at $OUT/logo_white_full.png"; exit 1; }

echo "== pdf"
node scripts/pdf_trailer/make_pdf.mjs "$OUT/Sommerfest-Programm.pdf"

echo "== seed"
mix run --no-start scripts/pdf_trailer/seed.exs > "$OUT/seed.log" 2>&1 || { tail -30 "$OUT/seed.log"; exit 1; }
grep '^SEED' "$OUT/seed.log"

echo "== server on port $PORT"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is busy; stop that server first (or set TRAILER_PORT)"; exit 1
fi
PORT=$PORT mix run --no-start scripts/pdf_trailer/server.exs > "$OUT/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
until grep -q TRAILER_SERVER_UP "$OUT/server.log" 2>/dev/null; do
  kill -0 $SERVER 2>/dev/null || { tail -30 "$OUT/server.log"; exit 1; }
  sleep 1
done
export TRAILER_BASE="http://localhost:$PORT"

echo "== login + record"
node scripts/pdf_trailer/login.mjs "$OUT/state.json"
node scripts/pdf_trailer/record.mjs "$OUT/state.json" "$OUT/Sommerfest-Programm.pdf" "$OUT"

kill $SERVER 2>/dev/null || true
trap - EXIT

echo "== render"
python3 scripts/pdf_trailer/render.py "$OUT"
