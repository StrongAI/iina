# usage: seekbefore.py <app> <file> <seconds> <full-length> <label>
# One run of seekbefore.sh. Opens <file> in the IINA copy at <app> and, as soon as the new iina.log holds
# "File loaded", sends mpv over its IPC socket the command IINA's absolute seek sends
# (PlayerCore.seek(absoluteSecond:)): seek <seconds> absolute+exact. Whether IINA had logged the file's
# full length when the seek was sent is read from the log right after mpv replies; that line is written
# before PlaybackInfo.fullLength is set. One second after the seek it reads where playback is, then
# waits for the full-length line and prints one row.
import glob, json, os, re, socket, subprocess, sys, time
app, path, target, full, label = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
LOGS = "/Users/asher/Library/Logs/com.colliderli.iina/*/iina.log"
LENGTH = "Full length of the file is"
def text(p):
    try:
        with open(p, errors="replace") as f: return f.read()
    except OSError: return ""
def send(command):
    s = socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect("/tmp/iina-mpv.sock")
    s.sendall((json.dumps({"command": command}) + "\n").encode()); buf = b""
    while True:
        buf += s.recv(65536)
        for line in buf.split(b"\n"):
            try: m = json.loads(line)
            except Exception: continue
            if "error" in m and "event" not in m: s.close(); return m
old = set(glob.glob(LOGS))
subprocess.run(["open", "-a", app, path], check=True)
log = None; end = time.monotonic() + 20
while time.monotonic() < end:
    log = log or next(iter(set(glob.glob(LOGS)) - old), None)
    if log and "[d] File loaded" in text(log): break
    time.sleep(0.002)
else:
    print("%s no File loaded line | NOT-EXERCISED" % label); sys.exit()
sent = time.monotonic()
reply = send(["seek", "%g" % target, "absolute+exact"])["error"]
early = LENGTH not in text(log)
time.sleep(max(0, 1 - (time.monotonic() - sent)))
pos = send(["get_property", "time-pos"]).get("data")
current = send(["get_property", "path"]).get("data") or ""
end = time.monotonic() + 10
while LENGTH not in text(log) and time.monotonic() < end: time.sleep(0.01)
m = re.search(LENGTH + r" ([\d.]+)s", text(log))
length = float(m.group(1)) if m else None
landed = current.endswith(os.path.basename(path)) and pos is not None and target - 1 <= pos <= target + 2
verdict = "NOT-EXERCISED" if not early else ("PASS" if reply == "success" and landed else "FAIL")
print("%s seek reply=%s sent_before_length=%s time-pos 1 s later=%s path=%s full_length=%s | %s" % (
    label, reply, "yes" if early else "no", "%.3f" % pos if pos is not None else "none", os.path.basename(current),
    "%.3f" % length if length is not None else "none",
    verdict if length is not None and abs(length - full) < 0.001 else "NO-LENGTH"))
