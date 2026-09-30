# usage: thumbwin.py <log> <label>
# Prints the thumbnail-related log lines around the last step, as ms offsets from the step line.
import sys, re
def t(s):
    h, m, r = s.split(":"); return (int(h) * 3600 + int(m) * 60 + float(r)) * 1000
rows = []
for l in open(sys.argv[1], errors="replace"):
    m = re.match(r"(\d\d:\d\d:\d\d\.\d+) (.*)", l)
    if m: rows.append((t(m.group(1)), m.group(2)))
a = max(i for i, r in enumerate(rows) if "Pausing playback before playing next" in r[1])
t0 = rows[a][0]
pat = re.compile(r"Getting thumbnails|Got new thumbnails|Got all thumbnails|thumbcache|Found thumbnail cache|Pausing playback before playing next|File started|File loaded|Resuming playback now")
out = []
for ts, msg in rows:
    if pat.search(msg):
        msg = re.sub(r"^\[player0\]\[d\] ", "", msg)
        out.append("%+d:%s" % (ts - t0, msg[:48]))
started = next((ts for ts, msg in rows[a:] if "File started" in msg), None)
resumed = next((ts for ts, msg in rows[a:] if "Resuming playback now" in msg), None)
prog_before = [r for r in rows[:a] if "Got new thumbnails" in r[1]]
prog_gap = [int(ts - t0) for ts, msg in rows[a:] if "Got new thumbnails" in msg and (started is None or ts < started)]
all_before = any("Got all thumbnails" in r[1] for r in rows[:a])
print("%s | progress lines before step=%d, scan finished before step=%s | progress lines between step and File started (+%d ms) at %s | step->playing %d ms" % (
    sys.argv[2], len(prog_before), all_before, started - t0, prog_gap, resumed - t0))
print("   " + " | ".join(out))
