#!/usr/bin/env bash
#
# Publish a release's priv/static tree to the directory nginx serves it from,
# with brotli and gzip variants precomputed.
#
# Why nginx and not Plug.Static: `gzip_static`/`brotli_static` can only hand out
# a precompressed file when nginx reads it off the filesystem itself. Until this
# script existed the vutuv.de vhost proxied /assets/ straight to the app, so both
# directives were dead config and nginx re-compressed every response on the fly
# at brotli level 6. Measured 2026-08-23 on the production bundle: 203,180 bytes
# on the fly against 184,983 precomputed at level 11, plus the CPU per request.
# (`mix phx.digest` writes its own .gz at zlib's default level; this script drops
# those and rebuilds at -9.)
#
# Additive, never --delete. During a blue/green switch the OLD release is still
# serving and its digested filenames must stay reachable; the digests make
# collisions impossible, so both releases' assets can coexist. Stale files are
# aged out by mtime instead: `cp -r` (deliberately NOT `-a`) stamps every file
# copied here with the current time, so anything a deploy stops publishing stops
# being refreshed and falls past the cutoff.
#
# Safe to run by hand against the live release; it only ever adds files:
#
#   sudo -u vutuv3 ./scripts/publish-static.sh \
#     /var/www/vutuv3/current/lib/vutuv-*/priv/static
#
# (from a readable cwd -- `find` refuses to run out of a directory the target
# user cannot enter, which /root is).
#
set -euo pipefail

DEST=${STATIC_DEST:-/srv/vutuv3/static}
PRUNE_DAYS=${STATIC_PRUNE_DAYS:-14}

SRC=${1:-}
if [ -z "$SRC" ]; then
  echo "usage: $0 <path-to-priv/static>" >&2
  exit 64
fi
if [ ! -d "$SRC" ]; then
  echo "ERROR: $SRC is not a directory" >&2
  exit 66
fi

mkdir -p "$DEST"
cp -r "$SRC"/. "$DEST"/

# Text types only, and only above 1 kB where the header overhead stops mattering.
# Images (avif/webp/png) are already compressed; running brotli over them costs
# CPU and gains nothing.
#
# Recompress a file only when its .br is missing or older than the source. That
# is a correctness rule before it is an optimisation: a stale .br is served
# INSTEAD of the source, so an undigested name whose content changed (app.js and
# app.css keep their URL across releases) would ship the previous deploy's bytes.
# `cp -r` above re-stamps everything this release publishes, so all of it counts
# as newer and is rebuilt, while the retained older releases keep the variants
# they already have — without that test every deploy would re-run brotli -q 11
# over the whole retention window.
compress_if_stale() {
  [ -f "$1.br" ] && [ ! "$1" -nt "$1.br" ] && return 0
  brotli -q 11 -f -o "$1.br" "$1" && gzip -9 -k -f "$1"
}
export -f compress_if_stale

find "$DEST" -type f -size +1k \
  \( -name "*.js" -o -name "*.css" -o -name "*.svg" -o -name "*.json" \
     -o -name "*.xml" -o -name "*.txt" -o -name "*.map" \) -print0 |
  xargs -0 -r -P 4 -I{} bash -c 'compress_if_stale "$1"' _ {}

# Age out assets from releases that are long gone. Anything the current release
# still publishes was just re-copied above, so its mtime is now.
find "$DEST" -type f -mtime "+$PRUNE_DAYS" -delete
find "$DEST" -mindepth 1 -type d -empty -delete

echo "published $SRC -> $DEST ($(du -sh "$DEST" | cut -f1))"
