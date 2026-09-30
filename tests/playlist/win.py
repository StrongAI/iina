import sys, re
def t(s):
    h, m, r = s.split(":"); return (int(h) * 3600 + int(m) * 60 + float(r)) * 1000
rows = []
for l in open(sys.argv[1], errors="replace"):
    m = re.match(r"(\d\d:\d\d:\d\d\.\d+) (.*)", l)
    if m: rows.append((t(m.group(1)), m.group(2)))
a = max(i for i, r in enumerate(rows) if "Pausing playback before playing next" in r[1])
b = next(i for i in range(a, len(rows)) if "Resuming playback now" in rows[i][1])
t0 = rows[a][0]
before = [r for r in rows[:a] if "Got new thumbnails" in r[1] and t0 - r[0] < 400]
inwin = [int(r[0] - t0) for r in rows[a:b + 1] if re.search(r"Got new thumbnails|Got all thumbnails|thumbcache", r[1])]
print("%s total=%4d scan-running-at-step=%s thumbnail-lines-in-window-at-ms=%s" % (sys.argv[2], rows[b][0] - t0, "yes" if before else "no", inwin))
