#!/usr/bin/env bash
#
# Build and deploy the vutuv production release on the server. Intended to be
# run by the self-hosted GitHub Actions runner (user `vutuv3` on bremen2) from
# a fresh checkout of the repo. Builds a release, runs migrations against
# vutuv3_prod, flips the `current` symlink atomically, and restarts the
# service. Does NOT touch nginx — the one-time domain cutover is manual.
#
set -euo pipefail

# The OTP application is :vutuv, so the release and its launcher are named
# `vutuv` (bin/vutuv, _build/prod/rel/vutuv). The OS user, service unit and
# install path use `vutuv3` to sit alongside the old `legacy-vutuv` instance
# and the stale /var/www/vutuv static dir without colliding.
RELEASE=vutuv
SERVICE=vutuv3
APP_ROOT=/var/www/vutuv3
RELEASES_DIR="$APP_ROOT/releases"
SHARED_ENV="$APP_ROOT/shared/.env"
KEEP_RELEASES=5

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

# Load runtime secrets (DB creds, SECRET_KEY_BASE, ...) so the migrate step
# can connect. The file is chmod 600 and never leaves the server.
set -a
# shellcheck disable=SC1090
source "$SHARED_ENV"
set +a

# Run migrations against the cloned production database (vutuv3_prod).
"$dest/bin/$RELEASE" eval "Vutuv.Release.migrate()"

# Atomically activate the new release.
ln -sfn "$dest" "$APP_ROOT/current"

# Restart via scoped sudoers (see /etc/sudoers.d/vutuv3).
sudo systemctl restart "$SERVICE"

# UUID cutover only: rename the image directories from their old integer id to
# the new UUID (avatars/covers/screenshots + their originals/ mirrors), using
# the legacy_id_map the convert_ids_to_uuid_v7 migration leaves behind. Must run
# before regenerate_images so the originals are found at their new UUID paths.
# Idempotent and a no-op once the map is cleaned up after the cutover.
"$dest/bin/$RELEASE" eval "Vutuv.Release.relabel_image_dirs()"

# Re-derive any image whose served versions predate the current
# Vutuv.Uploads.Spec (format/resolution/quality), relocating legacy public
# originals into the private originals/ tree. Idempotent and cheap when
# there is nothing to do; runs after the restart so new uploads are already
# on the current spec (a not-yet-converted file keeps serving through the
# transitional legacy fallback in the meantime).
"$dest/bin/$RELEASE" eval "Vutuv.Release.regenerate_images()"

# Keep only the most recent releases.
cd "$RELEASES_DIR"
ls -1dt */ 2>/dev/null | tail -n "+$((KEEP_RELEASES + 1))" | xargs -r rm -rf

echo "Deployed $SERVICE release $ts"
