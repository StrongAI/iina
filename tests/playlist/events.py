import json, socket, sys, time
# usage: events.py <seconds> <command> <arg>...   prints mpv events in order while sending one command
def conv(v):
    try:
        return float(v)
    except ValueError:
        return v
s = socket.socket(socket.AF_UNIX); s.connect("/tmp/iina-mpv.sock"); s.settimeout(0.2)
for i, p in enumerate(["pause", "eof-reached", "seeking", "playlist-pos", "core-idle"]):
    s.sendall((json.dumps({"command": ["observe_property", i + 1, p]}) + "\n").encode())
time.sleep(0.3)
t0 = time.time(); sent = False; buf = b""
while time.time() - t0 < float(sys.argv[1]):
    if not sent and time.time() - t0 > 0.5:
        s.sendall((json.dumps({"command": [sys.argv[2]] + [conv(v) for v in sys.argv[3:]]}) + "\n").encode()); sent = True
        print("%.3f SENT %s" % (time.time() - t0, sys.argv[2:]))
    try:
        buf += s.recv(65536)
    except socket.timeout:
        continue
    *lines, buf = buf.split(b"\n")
    for line in lines:
        try:
            m = json.loads(line)
        except Exception:
            continue
        if "event" in m:
            print("%.3f %s %s" % (time.time() - t0, m["event"], {k: v for k, v in m.items() if k not in ("event", "id")}))
