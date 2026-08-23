#!/usr/bin/env bash
#
# Blue/green zero-downtime deploy of the vutuv production release. Run by the
# self-hosted GitHub Actions runner (user `vutuv3` on bremen2) from a fresh
# checkout of the repo.
#
# Flow: build a release, run migrations, start it on the idle slot, wait until
# its /health probe answers, switch the nginx upstream, drain, stop the old
# slot. Users never hit a dead port; a failed build or boot leaves the old
# slot serving untouched.
#
# Because the old code keeps serving against the already-migrated database
# until the switch, MIGRATIONS MUST BE BACKWARD-COMPATIBLE. A deploy that
# cannot satisfy that (e.g. the one-time UUID v7 re-key prepared on the
# version-6 branch, see DEPLOY_TODO.md there) is a planned-downtime deploy
# and must be run deliberately, not pushed casually to main.
#
# Server-side layout (set up once, as root):
#   /var/www/vutuv3/
#     releases/<ts>/        unpacked mix releases
#     slots/blue|green      symlink, pins each slot to its release
#     current               convenience pointer to the live release
#     shared/.env           secrets (chmod 600)
#     shared/.env.blue      PORT=4003
#     shared/.env.green     PORT=4005
#     shared/active-slot    blue|green (absent = pre-blue/green legacy mode)
#   systemd: vutuv3@.service templated on the slot (scripts/systemd/)
#   nginx:   /etc/nginx/snippets/vutuv3-upstream.conf, rewritten on switch
#   sudoers: /etc/sudoers.d/vutuv3 scopes exactly the commands used below
#
set -euo pipefail

# The OTP application is :vutuv, so the release and its launcher are named
# `vutuv` (bin/vutuv, _build/prod/rel/vutuv). The OS user, service units and
# install path use `vutuv3`.
RELEASE=vutuv
APP=vutuv3
APP_ROOT=/var/www/vutuv3
RELEASES_DIR="$APP_ROOT/releases"
SLOTS_DIR="$APP_ROOT/slots"
SHARED_ENV="$APP_ROOT/shared/.env"
STATE_FILE="$APP_ROOT/shared/active-slot"
LOCK_FILE="$APP_ROOT/shared/.deploy.lock"
UPSTREAM_FILE=/etc/nginx/snippets/vutuv3-upstream.conf
KEEP_RELEASES=5
BLUE_PORT=4003
GREEN_PORT=4005
DRAIN_SECONDS=30
HEALTH_RETRIES=30
HEALTH_INTERVAL=2

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Belt and braces next to the workflow-level concurrency group: never let two
# deploys interleave on the server.
exec 9>"$LOCK_FILE"
flock -n 9 || { log "ERROR: another deploy holds $LOCK_FILE"; exit 1; }

# Determine the slots. `legacy` means the pre-blue/green single service
# (vutuv3.service on $BLUE_PORT) is still serving; the first blue/green
# deploy replaces it via the green slot and stops it like any old slot.
ACTIVE_SLOT=$(cat "$STATE_FILE" 2>/dev/null || echo legacy)
case "$ACTIVE_SLOT" in
  blue)  NEW_SLOT=green NEW_PORT=$GREEN_PORT OLD_UNIT="$APP@blue" ;;
  green) NEW_SLOT=blue  NEW_PORT=$BLUE_PORT  OLD_UNIT="$APP@green" ;;
  legacy) NEW_SLOT=green NEW_PORT=$GREEN_PORT OLD_UNIT="$APP" ;;
  *) log "ERROR: unknown active slot '$ACTIVE_SLOT' in $STATE_FILE"; exit 1 ;;
esac
NEW_UNIT="$APP@$NEW_SLOT"
log "Deploying: $ACTIVE_SLOT -> $NEW_SLOT (port $NEW_PORT)"

# Clean up an aborted deploy. `set -e` aborts the script but never tidies up,
# and a job killed from outside (the Actions cancel button, a runner timeout)
# does not even reach the health gate's error path below. Dying anywhere
# between `systemctl start` and the nginx reload would then leave the idle slot
# running: an orphaned beam.smp holding a database pool nobody can reach.
# $switched flips the moment nginx serves the new slot, because from then on
# $NEW_UNIT is the live one and stopping it would be the outage this script
# exists to avoid. $upstream_backup covers the few milliseconds in which the
# snippet already names the new port but nginx has not read it yet: leaving
# that behind would point the next unrelated reload (certbot, logrotate) at a
# stopped slot. A SIGKILL still escapes all of this, so the `systemctl stop`
# before the slot is repointed stays the backstop for the next deploy.
switched=0
upstream_backup=
cleanup() {
  local status=$?
  # Disarm EXIT against re-entry, and ignore a second signal: a runner sends
  # INT and then TERM, and being cut off midway is how the slot would survive
  # after all.
  trap - EXIT
  trap '' INT TERM HUP
  if [ "$switched" -eq 0 ]; then
    log "Aborted before the traffic switch; $ACTIVE_SLOT keeps serving traffic"
    if [ -n "$upstream_backup" ]; then
      printf '%s\n' "$upstream_backup" | sudo tee "$UPSTREAM_FILE" > /dev/null || true
    fi
    sudo systemctl stop "$NEW_UNIT" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'log "Deploy interrupted by a signal"; exit 143' INT TERM HUP

export MIX_ENV=prod

# Toolchain via mise (versions pinned in .tool-versions at the repo root).
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
mise install

# Build the release.
mix local.hex --force
mix local.rebar --force
mix deps.get --only prod
mix assets.setup
mix assets.deploy
mix release --overwrite

# Stage the assembled release into a timestamped directory.
ts="$(date +%Y%m%d%H%M%S)"
dest="$RELEASES_DIR/$ts"
mkdir -p "$dest"
cp -a "_build/prod/rel/$RELEASE/." "$dest/"

# Publish this release's digested assets to the tree nginx serves /assets/ from,
# with the brotli and gzip variants precomputed (scripts/publish-static.sh).
# Before the traffic switch, so the new HTML never names a file that is not on
# disk yet.
#
# Non-fatal on purpose: the vhost's `try_files $uri @app` falls back to
# Plug.Static, so a failure here costs on-the-fly compression and a proxy hop,
# never a broken page. That is not worth aborting a deploy over.
if ! ./scripts/publish-static.sh "$dest"/lib/vutuv-*/priv/static; then
  log "WARNING: publishing static assets failed; nginx falls back to the app"
fi

# If a previous deploy died between starting the slot and switching traffic,
# the idle slot may still run stale code — clear it before repointing.
sudo systemctl stop "$NEW_UNIT" 2>/dev/null || true

# Load runtime secrets (DB creds, SECRET_KEY_BASE, ...) so the migrate step
# can connect. The file is chmod 600 and never leaves the server.
set -a
# shellcheck disable=SC1090
source "$SHARED_ENV"
set +a

# Run migrations. The old slot keeps serving against the migrated schema
# until the switch — see the backward-compatibility note in the header.
"$dest/bin/$RELEASE" eval "Vutuv.Release.migrate()"

# Pin the idle slot to the new release and boot it.
ln -sfn "$dest" "$SLOTS_DIR/$NEW_SLOT"
sudo systemctl start "$NEW_UNIT"

# Gate: no traffic until the new instance serves /health (HTTP 200 with a
# live database connection) on its own port.
for i in $(seq 1 "$HEALTH_RETRIES"); do
  if curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$NEW_PORT/health"; then
    log "Health check passed (attempt $i)"
    break
  fi
  if [ "$i" -eq "$HEALTH_RETRIES" ]; then
    # The trap owns stopping the slot, on this path like on every other.
    log "ERROR: $NEW_SLOT never became healthy; $ACTIVE_SLOT still serves traffic"
    exit 1
  fi
  sleep "$HEALTH_INTERVAL"
done

# Switch traffic: rewrite the nginx upstream and reload. Reload is graceful —
# running requests and websockets finish on the old workers. Keep the previous
# snippet verbatim so the trap can put it back if we die before the reload.
upstream_backup=$(cat "$UPSTREAM_FILE" 2>/dev/null || true)
printf 'upstream vutuv3 {\n    server 127.0.0.1:%s;\n}\n' "$NEW_PORT" \
  | sudo tee "$UPSTREAM_FILE" > /dev/null
sudo nginx -t
sudo nginx -s reload
switched=1
log "Traffic switched to $NEW_SLOT"

# Record the new state; keep `current` as a convenience pointer for manual
# `bin/vutuv eval` sessions and backup scripts.
echo "$NEW_SLOT" > "$STATE_FILE"
ln -sfn "$dest" "$APP_ROOT/current"
sudo systemctl enable "$NEW_UNIT" 2>/dev/null || true
if [ "$ACTIVE_SLOT" = legacy ]; then
  sudo systemctl disable "$APP" 2>/dev/null || true
else
  sudo systemctl disable "$OLD_UNIT" 2>/dev/null || true
fi

# Everything from here on is MAINTENANCE, not deploy: traffic already runs on
# the new slot, so the deploy has succeeded. Such a step must therefore never
# be allowed to abort the script, because the one thing still outstanding —
# stopping the old slot — matters far more than any of it. `set -e` used to
# make a failure here fatal, and on 2026-08-09 that left both slots running
# for 40 minutes: two pools against a 100-connection Postgres (which was what
# had failed the maintenance step in the first place), and every periodic
# sweeper running twice, including the one that emails members about unread
# messages. Each step logs its own failure and the script carries on.
maintenance() {
  local what=$1
  shift
  if ! "$@"; then
    log "WARNING: $what failed; continuing so the old slot still gets stopped"
  fi
}

# UUID cutover only: rename the image directories from their old integer id to
# the new UUID (avatars/covers/screenshots + their originals/ mirrors), using
# the legacy_id_map the convert_ids_to_uuid_v7 migration leaves behind. Must run
# before regenerate_images so the originals are found at their new UUID paths.
# Idempotent and a no-op once the map is cleaned up after the cutover.
maintenance "relabel_image_dirs" "$dest/bin/$RELEASE" eval "Vutuv.Release.relabel_image_dirs()"

# Re-derive any image whose served versions predate the current
# Vutuv.Uploads.Spec (format/resolution/quality), relocating legacy public
# originals into the private originals/ tree. Idempotent and cheap when
# there is nothing to do; runs after the traffic switch so new uploads are
# already on the current spec (a not-yet-converted file keeps serving through
# the transitional legacy fallback in the meantime).
maintenance "regenerate_images" "$dest/bin/$RELEASE" eval "Vutuv.Release.regenerate_images()"

# Drain, then stop the old instance. The drain lets in-flight requests and
# LiveView websockets finish; it stays short because the app's periodic
# sweepers (e.g. unread-message emails) must not run twice for long.
log "Draining $ACTIVE_SLOT for ${DRAIN_SECONDS}s..."
sleep "$DRAIN_SECONDS"
sudo systemctl stop "$OLD_UNIT" 2>/dev/null || true
log "Stopped $ACTIVE_SLOT"

# Keep only the most recent releases, but never one a slot still points at.
pinned=$(readlink -f "$SLOTS_DIR/blue" 2>/dev/null; readlink -f "$SLOTS_DIR/green" 2>/dev/null; true)
find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d | sort | head -n "-$KEEP_RELEASES" \
  | while read -r old; do
      case "$pinned" in *"$(readlink -f "$old")"*) continue ;; esac
      rm -rf "$old"
    done

log "Deployed $APP release $ts on slot $NEW_SLOT (port $NEW_PORT)"
