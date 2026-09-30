import json, socket, sys, time
# usage: async.py <count> <intervalMs> <amount> <flags>   sends async seek commands and prints replies and events in order
s = socket.socket(socket.AF_UNIX); s.connect("/tmp/iina-mpv.sock"); s.settimeout(0.005)
t0 = time.time(); sent = 0; buf = b""; nxt = 0.3
count, interval = int(sys.argv[1]), int(sys.argv[2]) / 1000
while time.time() - t0 < 2.5:
    now = time.time() - t0
    if sent < count and now >= nxt:
        sent += 1; nxt = now + interval
        s.sendall((json.dumps({"command": ["seek", float(sys.argv[3]), sys.argv[4]], "async": True, "request_id": 100 + sent}) + "\n").encode())
        print("%.4f SENT %d" % (now, 100 + sent))
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
        ev = m.get("event")
        if ev in ("seek", "playback-restart", "end-file", "start-file", "file-loaded"):
            print("%.4f %s" % (time.time() - t0, ev))
        elif "request_id" in m and m["request_id"] >= 100:
            print("%.4f REPLY %d %s" % (time.time() - t0, m["request_id"], m.get("error")))
