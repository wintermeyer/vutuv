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
# Needs `brotli` on PATH, and uses `zopfli` for the gzip half when it is there
# (see gzip_best below); both are one apt package each and neither is required
# for the deploy to succeed.
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

# `mix phx.digest` writes its OWN .gz beside every digested file, at zlib's
# default level, and the copy above brought those along stamped with the current
# time. The staleness test further down would then read them as up to date and
# never replace them with the better ones, so the whole point of this script
# would be silently lost on the gzip half — measured once it happened: 215,574
# bytes from phx.digest against 207,884 from zopfli. Drop exactly the variants
# that came out of the release; the retained older releases keep theirs.
(cd "$SRC" && find . \( -name "*.gz" -o -name "*.br" \) -print) |
  sed 's|^\./||' |
  while IFS= read -r rel; do rm -f "$DEST/$rel"; done

# The gzip half, best effort. zopfli emits an ordinary gzip stream that every
# client already understands, roughly 3 % smaller than `gzip -9` (measured
# 2026-08-23 on the production bundle: 207,884 bytes against 215,079) for about
# two seconds of CPU per megabyte. That trade only works because this runs once
# per deploy and never per request. `--i15` is its default and the right one
# here: `--i50` cost twice the time for eighteen further bytes.
#
# Falls back to `gzip -9` when zopfli is absent, because a third-party
# installation should not need an extra package to deploy.
gzip_best() {
  if command -v zopfli > /dev/null 2>&1; then
    zopfli -c --i15 "$1"
  else
    gzip -9 -c "$1"
  fi
}

# Text types only, and only above 1 kB where the header overhead stops mattering.
# Images (avif/webp/png) are already compressed; running brotli over them costs
# CPU and gains nothing.
#
# Recompress a file only when its variant is missing or older than the source.
# That is a correctness rule before it is an optimisation: a compressed sibling
# is served INSTEAD of the source, so a stale one ships the previous deploy's
# bytes under a name whose content changed (app.js and app.css keep their URL
# across releases). `cp -r` above re-stamps everything this release publishes, so
# all of it counts as newer and is rebuilt, while the retained older releases
# keep the variants they already have — without that test every deploy would
# re-run brotli -q 11 over the whole retention window.
#
# Both halves write to a temporary name and move it into place only on success,
# for the same reason: an interrupted compressor would otherwise leave a
# truncated .br or .gz that nginx serves in preference to the intact source.
compress_if_stale() {
  local src=$1

  if [ ! -f "$src.br" ] || [ "$src" -nt "$src.br" ]; then
    if brotli -q 11 -f -o "$src.br.tmp" "$src"; then
      mv -f "$src.br.tmp" "$src.br"
    else
      rm -f "$src.br.tmp"
      return 1
    fi
  fi

  if [ ! -f "$src.gz" ] || [ "$src" -nt "$src.gz" ]; then
    if gzip_best "$src" > "$src.gz.tmp"; then
      mv -f "$src.gz.tmp" "$src.gz"
    else
      rm -f "$src.gz.tmp"
      return 1
    fi
  fi
}
export -f gzip_best compress_if_stale

find "$DEST" -type f -size +1k \
  \( -name "*.js" -o -name "*.css" -o -name "*.svg" -o -name "*.json" \
     -o -name "*.xml" -o -name "*.txt" -o -name "*.map" \) -print0 |
  xargs -0 -r -P 4 -I{} bash -c 'compress_if_stale "$1"' _ {}

# Age out assets from releases that are long gone. Anything the current release
# still publishes was just re-copied above, so its mtime is now.
find "$DEST" -type f -mtime "+$PRUNE_DAYS" -delete
find "$DEST" -mindepth 1 -type d -empty -delete

echo "published $SRC -> $DEST ($(du -sh "$DEST" | cut -f1))"
