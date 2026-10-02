# usage: fragstats.py <logdir>
# One row per run of fragstep.sh, read from the run's iina.log: the step times as mpvstats.py reads
# them, and when the full-length work of the file left and of the file stepped to finished. The work
# logs "Full length of the file is" only for a file that is still current when it finishes, so no such
# line for the file left before the step means the work was still running when the step was given.
import sys, re, os
def t(s):
    h, m, r = s.split(":"); return (int(h) * 3600 + int(m) * 60 + float(r)) * 1000
step = None; starts = []; resumes = []; lengths = []
for line in open(os.path.join(sys.argv[1], "iina.log"), errors="replace"):
    m = re.match(r"(\d\d:\d\d:\d\d\.\d+) ", line)
    if not m: continue
    ts = t(m.group(1))
    if "un command: playlist-next" in line:
        if step is None: step = ts
    elif "[d] File started" in line: starts.append(ts)
    elif "Resuming playback now that file has been loaded" in line: resumes.append(ts)
    else:
        g = re.search(r"Full length of the file is ([\d.]+)s", line)
        if g: lengths.append((ts, float(g.group(1))))
f = lambda a, b: "NA" if a is None or b is None else "%d" % (b - a)
first = lambda xs, lo: next((x for x in xs if x >= lo), None)
left_resume = max((r for r in resumes if step is not None and r < step), default=None)
started = first(starts, step) if step is not None else None
resumed = first(resumes, started) if started is not None else None
left_len = [v for ts, v in lengths if left_resume is not None and left_resume <= ts < step]
new_len = [(ts, v) for ts, v in lengths if started is not None and ts >= started]
early = sum(1 for ts, v in new_len if resumed is None or ts < resumed)
print("step_started=%s started_playing=%s total=%s left_resume_to_step=%s left_length_before_step=%s new_length=%s new_resume_to_length=%s lengths_before_resume=%d dir=%s" % (
    f(step, started), f(started, resumed), f(step, resumed), f(left_resume, step),
    "%.3f" % left_len[0] if left_len else "none",
    "%.3f" % new_len[0][1] if new_len else "none",
    f(resumed, new_len[0][0]) if new_len else "NA", early, os.path.basename(sys.argv[1].rstrip("/"))))
