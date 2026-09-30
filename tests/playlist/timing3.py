# usage: timing3.py <log> <label>
# One row per run: the times around the last step, and whether every thumbnail scan began after its entry resumed.
import sys, re
def t(s):
    h, m, r = s.split(":"); return (int(h) * 3600 + int(m) * 60 + float(r)) * 1000
step = started = resumed = None; resumed_since_start = False; getting = 0; getting_early = 0
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"(\d\d:\d\d:\d\d\.\d+) ", line)
    if not m: continue
    ts = t(m.group(1))
    if "Pausing playback before playing next" in line: step = ts; started = resumed = None
    elif "[d] File started" in line:
        resumed_since_start = False
        if step is not None and started is None: started = ts
    elif "Resuming playback now that file has been loaded" in line:
        resumed_since_start = True
        if started is not None and resumed is None: resumed = ts
    elif "[d] Getting thumbnails" in line:
        getting += 1
        if not resumed_since_start: getting_early += 1
f = lambda a, b: "NA" if a is None or b is None else "%d" % (b - a)
print("%s step_started=%s started_playing=%s total=%s scans=%d scans_before_resume=%d" % (sys.argv[2], f(step, started), f(started, resumed), f(step, resumed), getting, getting_early))
