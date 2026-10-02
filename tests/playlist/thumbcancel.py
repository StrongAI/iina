# usage: thumbcancel.py <log> <label>
# Judges one run of the thumbnail-cancellation case from the log lines around the last step.
import sys, re
def t(s):
    h, m, r = s.split(":"); return (int(h) * 3600 + int(m) * 60 + float(r)) * 1000
rows = []
for l in open(sys.argv[1], errors="replace"):
    m = re.match(r"(\d\d:\d\d:\d\d\.\d+) (.*)", l)
    if m: rows.append((t(m.group(1)), m.group(2)))
# The step is sent to mpv synchronously or asynchronously, and logged as "Run command" or "Asynchronously run command".
steps = [i for i, r in enumerate(rows) if "un command: playlist-next" in r[1]]
if not steps:
    print("%s no step in the log | NO-STEP" % sys.argv[2]); sys.exit(0)
a = steps[-1]
t0 = rows[a][0]
b = next(i for i in range(a, len(rows)) if "[d] File started" in rows[i][1])
before = [t0 - ts for ts, msg in rows[:a] if "Got new thumbnails" in msg]
finished_before = any("Got all thumbnails" in msg for ts, msg in rows[:a])
running = bool(before) and min(before) <= 250 and not finished_before
gap = rows[a:b]
progress = [int(ts - t0) for ts, msg in gap if "Got new thumbnails" in msg]
done = [int(ts - t0) for ts, msg in gap if "Got all thumbnails" in msg or "thumbcache" in msg]
verdict = "NOT-EXERCISED" if not running else ("PASS" if len(progress) <= 1 and not done else "FAIL")
print("%s last progress line %d ms before the step (of %d), finished before step=%s | step to File started %d ms: progress lines at %s, completion or cache lines at %s | %s" % (
    sys.argv[2], min(before) if before else -1, len(before), finished_before, rows[b][0] - t0, progress, done, verdict))
