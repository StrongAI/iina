import sys, re
def t(s):
    h, m, r = s.split(":"); return (int(h) * 3600 + int(m) * 60 + float(r)) * 1000
lines = open(sys.argv[1], errors="replace").read().split("\n")
a = max(i for i, l in enumerate(lines) if "Pausing playback before playing next" in l)
b = next(i for i in range(a, len(lines)) if "Resuming playback now" in lines[i])
prev = None; t0 = None
for l in lines[a:b + 1]:
    m = re.match(r"(\d\d:\d\d:\d\d\.\d+) (.*)", l)
    if not m: continue
    now = t(m.group(1)); t0 = t0 or now
    if prev is not None and now - prev[0] > 80:
        print("  +%4d ms  gap %4d ms after: %s" % (prev[0] - t0, now - prev[0], prev[1][:95]))
        print("  +%4d ms          next: %s" % (now - t0, m.group(2)[:95]))
    if re.search(r"humbnail|File started|File loaded|Resuming playback now", m.group(2)):
        print("  +%4d ms  %s" % (now - t0, m.group(2)[:95]))
    prev = (now, m.group(2))
print("total %d ms" % (prev[0] - t0))
