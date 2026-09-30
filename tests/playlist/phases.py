# usage: phases.py <results-file>
# Splits each run's step into mpv's own phases (from mpv.log) and compares cache on with cache off per phase.
import sys, re, os, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
base = "/Users/admin/Library/Logs/com.colliderli.iina/"
marks = ["Run command: playlist-next", "] Playing: ", "Opening done:", "Starting playback...", "Decoder format:", "first video frame after restart shown", "playback restart complete"]
names = ["next->Playing", "Playing->Opening done", "Opening done->Starting playback", "Starting playback->Decoder format", "Decoder format->first frame shown", "first frame shown->restart complete"]
data = {"on": [], "off": []}
for l in open(sys.argv[1]):
    if "step_started=" not in l or "step_started=NA" in l: continue
    cond = re.search(r"cache=(on|off)", l).group(1); d = re.search(r"dir=(\S+)", l).group(1)
    ml = open(base + d + "/mpv.log", errors="replace").read().split("\n")
    n = max(i for i, x in enumerate(ml) if marks[0] in x)
    ts = []; i = n
    for mk in marks:
        j = next((k for k in range(i, len(ml)) if mk in ml[k]), None)
        if j is None: ts.append(None); continue
        ts.append(float(re.match(r"\[\s*([\d.]+)\]", ml[j]).group(1)) * 1000); i = j
    data[cond].append(ts)
import importlib.util
spec = importlib.util.spec_from_file_location("mwu", "/Users/admin/Projects/iina-test/mwu_core.py"); mw = importlib.util.module_from_spec(spec); spec.loader.exec_module(mw)
for k, nm in enumerate(names):
    s = {c: [r[k + 1] - r[k] for r in data[c] if r[k] is not None and r[k + 1] is not None] for c in data}
    if not s["on"] or not s["off"]: print("%s: marker missing" % nm); continue
    q = lambda xs: "%d/%d/%d" % tuple(statistics.quantiles(xs, n=4))
    print("%-36s on n=%d quartiles %s | off n=%d quartiles %s | p(on>off)=%.3f" % (nm, len(s["on"]), q(s["on"]), len(s["off"]), q(s["off"]), mw.p_greater(s["on"], s["off"])))
