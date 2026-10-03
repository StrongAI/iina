# usage: seekcheck.sh
# Opens frag-62m.mp4 (a fragmented MP4 ending in an mfra index, 3720.021 s long, for which mpv reports
# about 229 s), waits until IINA has logged its full length, then clicks the play slider at a quarter,
# half and nine tenths of its width with axctl and reads mpv's position a second later. Each click must
# leave the slider within 1 of 100 of the fraction clicked, and each seek must land between 1 s before
# (a keyframe every 0.8 s) and 2 s after the slider's value, as a fraction of its maximum, times the
# full length.
D=$(cd "$(dirname "$0")" && pwd); source $D/lib.sh
FULL=3720.021
quit_iina; open_file $MEDIA/frag/frag-62m.mp4
python3 $D/waitlog.py "$(lastlog)" "Full length of the file is" 20 || echo "no full length logged"
grep -E "Full length of the file is" "$(lastlog)"
for f in 0.25 0.5 0.9; do
  out=$($D/axctl $APP slide $f); sleep 1
  pos=$(ipc time-pos | sed -E 's/.*= //')
  python3 - "$out" "$pos" "$FULL" "$f" <<'PY'
import re, sys
out, pos, full, f = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
m = re.search(r"value=([\d.]+) max=([\d.]+)", out)
if not m: print("click at %s: %s | FAIL" % (f, out)); sys.exit()
at = float(m.group(1)) / float(m.group(2))
want = at * full
ok = abs(at - float(f)) <= 0.01 and -1 <= pos - want <= 2
print("click at %s: slider %s of %s, time-pos %.1f s, expected %.1f s | %s" % (
    f, m.group(1), m.group(2), pos, want, "PASS" if ok else "FAIL"))
PY
done
quit_iina
