# usage: assembly_restart.py <folder> <opened-file-name> <app>
# Opens the file and restarts it over IPC while the folder is still being listed, before any file
# has been added to the playlist, then checks that the playlist ends up holding every file in the
# folder. A restart starts the file again, as a step forward does when the playlist loops and the
# opened file is its only entry.
import json, os, re, socket, subprocess, sys, time, glob
folder, opened, app = sys.argv[1], sys.argv[2], sys.argv[3]
SOCK = "/tmp/iina-mpv.sock"

class IPC:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX); self.s.settimeout(30); self.s.connect(SOCK); self.buf = b""
    def call(self, *command):
        self.s.sendall((json.dumps({"command": list(command)}) + "\n").encode())
        while True:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                try: m = json.loads(line)
                except Exception: continue
                if "error" in m and "event" not in m: return m.get("data")
            self.buf += self.s.recv(1 << 20)
    def get(self, prop):
        return self.call("get_property", prop)

names = sorted(n for n in os.listdir(folder) if n.endswith(".mp4"))
subprocess.run(["open", "-a", app, os.path.join(folder, opened)], check=True)
ipc = None
for _ in range(400):
    try:
        ipc = IPC(); break
    except Exception:
        time.sleep(0.025)
while not ipc.get("path"):
    pass
count_at_restart = ipc.get("playlist-count")
ipc.call("playlist-play-index", 0)
last, stable = None, 0
for _ in range(600):
    c = ipc.get("playlist-count")
    stable = stable + 1 if c == last else 0
    last = c
    if stable >= 10: break
    time.sleep(0.2)
time.sleep(2)
got = [e["filename"].split("/")[-1] for e in ipc.get("playlist")]
log = max(glob.glob("/Users/asher/Library/Logs/com.colliderli.iina/*/iina.log"), key=os.path.getmtime)
def t(s):
    h, m, x = s.split(":"); return (int(h) * 3600 + int(m) * 60 + float(x)) * 1000
starts = []; first = None; loads = 0
for line in open(log, errors="replace"):
    m = re.match(r"(\d\d:\d\d:\d\d\.\d+) ", line)
    if not m: continue
    if "File started" in line: starts.append(t(m.group(1)))
    elif "Run command: loadfile" in line and (" append" in line or " insert-at " in line):
        loads += 1; first = first if first is not None else t(m.group(1))
before = [s for s in starts if first is None or s < first]
print("folder files=%d playlist entries=%d distinct=%d in-folder-order=%s" % (len(names), len(got), len(set(got)), got == names))
print("playlist-count when the restart was issued=%s, file starts=%d, of which before the first add=%d, add/insert load commands=%d" % (count_at_restart, len(starts), len(before), loads))
inside = count_at_restart == 1 and len(before) >= 2
print("restart before the first add=%s RESULT=%s" % (inside, "PASS" if inside and got == names else "FAIL"))
