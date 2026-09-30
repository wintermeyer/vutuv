#!/bin/sh
# Produces the German Arbeitszeugnis trailer, start to finish (~6 minutes,
# most of it the real analysis on the Ollama instance OLLAMA_URL names).
#
#   scripts/reference_trailer/run.sh
#
# Result: _build/reference_trailer/vutuv-zeugnis-trailer-de.mp4 (1920x1080,
# silent) and a poster PNG. A fictional member (Friedhelm Pöttering, seed.exs)
# adds his Zeugnis, has it decoded and opens the result. The Zeugnis is test
# file 04 of the upstream skill (MIT), fetched at a pinned commit so the film
# does not change under us. Needs poppler-utils, Google Chrome and an Ollama
# instance with the check's model (Vutuv.References.Analyst.model/0).
set -eu
cd "$(dirname "$0")/../.."
OUT=_build/reference_trailer
PORT=${TRAILER_PORT:-4079}
SKILL_COMMIT=e13ef1a
ZEUGNIS=testakten/arbeitszeugnis-analyse-bluehendes-leben/04-friedhelm-poettering-lagermeister/Arbeitszeugnis_04-friedhelm-poettering-lagermeister.pdf
mkdir -p "$OUT"

[ -d scripts/reference_trailer/node_modules ] || (cd scripts/reference_trailer && npm install --silent)
[ -f "$OUT/logo_white_full.png" ] || node scripts/reference_trailer/logo.mjs "$OUT/logo_white_full.png"
[ -f "$OUT/Arbeitszeugnis.pdf" ] ||
  curl -fsSL -o "$OUT/Arbeitszeugnis.pdf" \
    "https://raw.githubusercontent.com/Klotzkette/arbeitszeugnispruefer-skill/$SKILL_COMMIT/$ZEUGNIS"

echo "== seed"
mix run --no-start scripts/reference_trailer/seed.exs > "$OUT/seed.log" 2>&1 || { tail -30 "$OUT/seed.log"; exit 1; }
grep '^SEED' "$OUT/seed.log"

echo "== server on port $PORT"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is busy; stop that server first (or set TRAILER_PORT)"; exit 1
fi
PORT=$PORT mix run --no-start scripts/reference_trailer/server.exs > "$OUT/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
until grep -q TRAILER_SERVER_UP "$OUT/server.log" 2>/dev/null; do
  kill -0 $SERVER 2>/dev/null || { tail -30 "$OUT/server.log"; exit 1; }
  sleep 1
done
export TRAILER_BASE="http://localhost:$PORT"

echo "== login + record (the check takes minutes)"
node scripts/reference_trailer/login.mjs "$OUT/state.json"
node scripts/reference_trailer/record.mjs "$OUT/state.json" "$OUT/Arbeitszeugnis.pdf" "$OUT"

kill $SERVER 2>/dev/null || true
trap - EXIT

echo "== render"
python3 scripts/reference_trailer/render.py "$OUT"
