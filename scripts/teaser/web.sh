#!/bin/sh
# The start page's copies of the teaser, from the masters run.sh leaves behind,
# each as AV1 with an H.264 fallback:
#   vutuv-teaser-<lang>.{av1.mp4,mp4}           960x540, the desktop plays this
#   vutuv-teaser-<lang>.hd.{av1.mp4,mp4}        1920x1080, behind the HD toggle
#   vutuv-teaser-<lang>-portrait.{av1.mp4,mp4}  720x1280, a phone plays this
#   vutuv-teaser-<lang>.avif                    the poster (the three phones)
#
#   scripts/teaser/web.sh     # after run.sh <lang> and run.sh <lang> --portrait
#
# Result: priv/static/images/teaser/
set -eu
cd "$(dirname "$0")/../.."
OUT=priv/static/images/teaser
mkdir -p "$OUT"

encode() { # <master> <scale filter> <name>: decodes once, writes both codecs
  ffmpeg -v error -y -i "$1" -filter_complex "[0:v]$2,split=2[av1][avc]" \
    -map "[av1]" -c:v libsvtav1 -preset 3 -crf 38 -g 300 -pix_fmt yuv420p \
    -svtav1-params tune=0 -movflags +faststart -an "$OUT/$3.av1.mp4" \
    -map "[avc]" -c:v libx264 -preset veryslow -tune animation -crf 24 -pix_fmt yuv420p \
    -profile:v high -movflags +faststart -an "$OUT/$3.mp4"
}

for l in de en; do
  encode "_build/teaser/$l/master.mp4" scale=960:540:flags=lanczos "vutuv-teaser-$l"
  encode "_build/teaser/$l/master.mp4" null "vutuv-teaser-$l.hd"
  encode "_build/teaser/$l/portrait/master.mp4" scale=720:1280:flags=lanczos "vutuv-teaser-$l-portrait"
  # the poster as AVIF: every browser that plays the AV1 film decodes it
  ffmpeg -v error -y -i "_build/teaser/$l/vutuv-teaser-$l-poster.png" \
    -vf scale=960:540:flags=lanczos "_build/teaser/$l/poster-960.png"
  avifenc -q 60 -s 4 "_build/teaser/$l/poster-960.png" "$OUT/vutuv-teaser-$l.avif" > /dev/null
done
ls -la "$OUT"
