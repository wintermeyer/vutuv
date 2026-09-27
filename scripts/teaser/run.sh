#!/bin/sh
# Produces the teaser for one language, start to finish: both formats, the 16:9
# desktop cut and the 9:16 phone cut.
#
#   scripts/teaser/run.sh de        # or: en
#   scripts/teaser/run.sh de --no-record   # cut again from the existing takes
#   scripts/teaser/run.sh de --portrait    # take and cut only the phone format
#
# Each format is one take: seed, start the server, log in, record all of its
# scenes, stop. The seed comes first every time because a take changes the
# state (Anna's tag vote, the like and repost, the composer's draft), and every
# scene of a format is recorded after the same seed, so the post shows one
# time of day throughout that film.
#
# Result: _build/teaser/<lang>/vutuv-teaser-<lang>.mp4 and ...-poster.png, the
# phone cut under _build/teaser/<lang>/portrait/ (vutuv-teaser-<lang>-portrait.*).
# See scripts/teaser/README.md for the storyboard and what each step does.
set -eu
LANG_CODE=${1:?usage: run.sh <de|en> [--no-record | --portrait]}
MODE=${2:-}
cd "$(dirname "$0")/../.."
OUT=_build/teaser/$LANG_CODE
PORT=${TEASER_PORT:-4077}
mkdir -p "$OUT"

take() { # <recorder>: one seeded take of every scene the recorder knows
  echo "== seed ($LANG_CODE)"
  mix run --no-start scripts/teaser/seed.exs "$LANG_CODE" "$OUT" > "$OUT/seed.log" 2>&1 || { tail -30 "$OUT/seed.log"; exit 1; }
  grep '^SEED' "$OUT/seed.log"

  echo "== server on port $PORT"
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $PORT is busy; stop that server first (or set TEASER_PORT)"; exit 1
  fi
  PORT=$PORT mix run --no-start scripts/teaser/server.exs "$LANG_CODE" > "$OUT/server.log" 2>&1 &
  SERVER=$!
  trap 'kill $SERVER 2>/dev/null || true' EXIT
  until grep -q TEASER_SERVER_UP "$OUT/server.log" 2>/dev/null; do
    kill -0 $SERVER 2>/dev/null || { tail -30 "$OUT/server.log"; exit 1; }
    sleep 1
  done
  export TEASER_BASE="http://localhost:$PORT"

  echo "== login"
  node scripts/teaser/login.mjs miriam.kessler@example.com "$OUT/state-miriam.json"
  node scripts/teaser/login.mjs anna.berger@example.com "$OUT/state-anna.json"

  echo "== record ($1)"
  node "scripts/teaser/$1" "$LANG_CODE"

  kill $SERVER 2>/dev/null || true
  wait $SERVER 2>/dev/null || true
  trap - EXIT
  echo "stub hits (fediverse requests that never left this machine): $(grep -c FEDI_STUB "$OUT/server.log" || true)"
}

if [ "$MODE" != "--no-record" ]; then
  [ -d scripts/teaser/node_modules ] || (cd scripts/teaser && npm install --silent)
  python3 scripts/teaser/assets.py
  node scripts/teaser/render_assets.mjs "$LANG_CODE"
  [ "$MODE" = "--portrait" ] || take record.mjs
  take record_portrait.mjs
fi

echo "== render"
[ "$MODE" = "--portrait" ] || python3 scripts/teaser/render.py "$LANG_CODE"
python3 scripts/teaser/render.py "$LANG_CODE" --portrait
