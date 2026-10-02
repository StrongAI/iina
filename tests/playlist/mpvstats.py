# usage: mpvstats.py <setting: cache|thumbs> <wait> <logdir>...
# One row per run, read from iina.log and mpv.log in the log directory of the run: the setting as the log
# records it, the step times, whether each thumbnail scan began after its entry resumed, how long mpv took to
# terminate the demuxers of the entry left, and how many times mpv reported the render stalled between the
# step and the start of playback of the next entry.
import sys, re, os
def t(s):
    h, m, r = s.split(":"); return (int(h) * 3600 + int(m) * 60 + float(r)) * 1000
setting, wait = sys.argv[1], sys.argv[2]
for d in sys.argv[3:]:
    il = open(os.path.join(d, "iina.log"), errors="replace").read().split("\n")
    cond = None; step = started = resumed = None; resumed_since_start = False; scans = early = 0
    for line in il:
        m = re.match(r"(\d\d:\d\d:\d\d\.\d+) ", line)
        if not m: continue
        ts = t(m.group(1))
        if setting == "cache" and cond is None and "Set option: cache=" in line: cond = "on" if line.strip().endswith("yes") else "off"
        if "un command: playlist-next" in line: step = ts; started = resumed = None
        elif "[d] File started" in line:
            resumed_since_start = False
            if step is not None and started is None: started = ts
        elif "Resuming playback now that file has been loaded" in line:
            resumed_since_start = True
            if started is not None and resumed is None: resumed = ts
        elif "[d] Getting thumbnails" in line:
            scans += 1; early += not resumed_since_start
    if setting == "thumbs": cond = "on" if any("Got new thumbnails" in l or "Found thumbnail cache" in l for l in il) else "off"
    ml = open(os.path.join(d, "mpv.log"), errors="replace").read().split("\n")
    n = max((i for i, l in enumerate(ml) if "un command: playlist-next" in l), default=None)
    teardown = stuck = None
    if n is not None:
        mt = lambda l: float(re.match(r"\[\s*([\d.]+)\]", l).group(1)) * 1000
        a = next((i for i in range(n, len(ml)) if "Terminating demuxers..." in ml[i]), None)
        b = next((i for i in range(n, len(ml)) if "Done terminating demuxers." in ml[i]), None)
        c = next((i for i in range(n, len(ml)) if "Starting playback..." in ml[i]), len(ml))
        if a is not None and b is not None: teardown = mt(ml[b]) - mt(ml[a])
        stuck = sum("not being called or stuck" in l for l in ml[n:c])
    f = lambda a, b: "NA" if a is None or b is None else "%d" % (b - a)
    print("%s=%s wait=%s step_started=%s started_playing=%s total=%s demuxer_teardown=%s render_stalls=%s scans=%d scans_before_resume=%d dir=%s" % (
        setting, cond, wait, f(step, started), f(started, resumed), f(step, resumed),
        "NA" if teardown is None else "%d" % teardown, stuck, scans, early, os.path.basename(d)))
