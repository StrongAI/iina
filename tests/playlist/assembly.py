# usage: assembly.py <folder> <opened-file-name> <app>
# Opens the file, steps forward with the Next Media menu command as soon as the folder playlist
# starts being assembled, then checks the playlist and where the step fell in the log.
import json, os, re, socket, subprocess, sys, time, glob
folder, opened, app = sys.argv[1], sys.argv[2], sys.argv[3]
SOCK = "/tmp/iina-mpv.sock"
CLICK = ["osascript", "-e", "tell application \"System Events\" to tell process \"IINA\" to click menu item \"Next Media\" of menu \"Playback\" of menu bar item \"Playback\" of menu bar 1"]

class IPC:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX); self.s.settimeout(30); self.s.connect(SOCK); self.buf = b""
    def get(self, prop):
        self.s.sendall((json.dumps({"command": ["get_property", prop]}) + "\n").encode())
        while True:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                try: m = json.loads(line)
                except Exception: continue
                if "error" in m and "event" not in m: return m.get("data")
            self.buf += self.s.recv(1 << 20)

names = sorted(n for n in os.listdir(folder) if n.endswith(".mp4"))
subprocess.run(["open", "-a", app, os.path.join(folder, opened)], check=True)
ipc = None
for _ in range(400):
    try:
        ipc = IPC(); break
    except Exception:
        time.sleep(0.025)
while True:
    c = ipc.get("playlist-count")
    if isinstance(c, int) and c >= 2: break
count_at_click = c
r = subprocess.run(CLICK, capture_output=True)
count_after_click = ipc.get("playlist-count")
last, stable = None, 0
for _ in range(600):
    c = ipc.get("playlist-count")
    stable = stable + 1 if c == last else 0
    last = c
    if stable >= 10: break
    time.sleep(0.2)
time.sleep(2)
pl = ipc.get("playlist")
got = [e["filename"].split("/")[-1] for e in pl]
cur = [i for i, e in enumerate(pl) if e.get("current")]
log = max(glob.glob("/Users/admin/Library/Logs/com.colliderli.iina/*/iina.log"), key=os.path.getmtime)
def t(s):
    h, m, x = s.split(":"); return (int(h) * 3600 + int(m) * 60 + float(x)) * 1000
first = lastload = None; steps = []; notplaying = 0; loads = 0
for line in open(log, errors="replace"):
    m = re.match(r"(\d\d:\d\d:\d\d\.\d+) ", line)
    if not m: continue
    if "Run command: loadfile" in line and (" append" in line or " insert-at " in line):
        loads += 1; lastload = t(m.group(1)); first = first if first is not None else lastload
    elif "Pausing playback before playing next entry" in line: steps.append(t(m.group(1)))
    elif "Not playing next entry" in line: notplaying += 1
oi = names.index(opened)
print("folder files=%d playlist entries=%d distinct=%d in-folder-order=%s" % (len(names), len(got), len(set(got)), got == names))
print("opened=%s (index %d) current=%s" % (opened, oi, [(i, got[i]) for i in cur]))
print("playlist-count when the step was issued=%s, right after the click returned=%s, click rc=%d" % (count_at_click, count_after_click, r.returncode))
print("log=%s add/insert load commands=%d assembly took %.0f ms" % (log, loads, lastload - first))
print("step lines=%d at +%s ms after the first load command; not-playing-next lines=%d" % (len(steps), [round(s - first) for s in steps], notplaying))
inside = len(steps) == 1 and first < steps[0] < lastload
ok = inside and got == names and cur == [oi + 1]
print("step inside assembly=%s RESULT=%s" % (inside, "PASS" if ok else "FAIL"))
