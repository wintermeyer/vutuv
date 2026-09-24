#!/bin/sh
# Produces the teaser video for one language, start to finish.
#
#   scripts/teaser/run.sh de                   # or: en; the 16:9 desktop cut
#   scripts/teaser/run.sh de --portrait        # the 9:16 phone cut
#   scripts/teaser/run.sh de feed              # re-record only some scenes, then re-render
#   scripts/teaser/run.sh de --portrait feed
#
# Result: _build/teaser/<lang>/vutuv-teaser-<lang>.mp4 and ...-poster.png, the
# phone cut under _build/teaser/<lang>/portrait/ (vutuv-teaser-<lang>-portrait.*).
# See scripts/teaser/README.md for the storyboard and what each step does.
set -eu
LANG_CODE=${1:?usage: run.sh <de|en> [--portrait] [scene ...]}
shift
RECORDER=record.mjs
RENDER_FLAG=""
if [ "${1:-}" = "--portrait" ]; then
  RECORDER=record_portrait.mjs
  RENDER_FLAG=--portrait
  shift
fi
cd "$(dirname "$0")/../.."
OUT=_build/teaser/$LANG_CODE
PORT=${TEASER_PORT:-4077}
mkdir -p "$OUT"

[ -d scripts/teaser/node_modules ] || (cd scripts/teaser && npm install --silent)
python3 scripts/teaser/assets.py
node scripts/teaser/render_assets.mjs "$LANG_CODE"

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

echo "== record"
node "scripts/teaser/$RECORDER" "$LANG_CODE" "$@"

kill $SERVER 2>/dev/null || true
trap - EXIT

echo "== render"
python3 scripts/teaser/render.py "$LANG_CODE" $RENDER_FLAG
echo "stub hits (fediverse requests that never left this machine): $(grep -c FEDI_STUB "$OUT/server.log" || true)"
