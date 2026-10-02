# usage: seekbefore.sh [runs]
# Opens frag-62m.mp4 (a fragmented MP4 ending in an mfra index, 3720.021 s by a full parse, for which mpv
# reports about 229 s) <runs> times (10 by default). In each run seekbefore.py seeks to 3000 s, beyond the
# duration mpv reports, with the command IINA's absolute seek sends, as soon as IINA logs "File loaded" and
# so before it logs the file's full length, and reads where playback is one second later.
source "$(dirname "$0")/lib.sh"
for i in $(seq 1 ${1:-10}); do
  quit_iina; python3 $TESTS/seekbefore.py "$APP" $MEDIA/frag/frag-62m.mp4 3000 3720.021 "run $i:"
done; quit_iina
