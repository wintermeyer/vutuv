#!/bin/sh
# Everything the start page plays, from scratch: both languages, both formats
# (16:9 for the desktop, 9:16 for the phone), then the web copies.
#
#   scripts/teaser/all.sh
#
# About an hour. Each run seeds the database again, so every take starts from
# the same state. Result: priv/static/images/teaser/ (see web.sh).
set -eu
cd "$(dirname "$0")/../.."
for l in de en; do
  scripts/teaser/run.sh "$l"
  scripts/teaser/run.sh "$l" --portrait
done
scripts/teaser/web.sh
