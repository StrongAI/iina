import json, socket, sys
def q(prop):
    s = socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect("/tmp/iina-mpv.sock")
    s.sendall((json.dumps({"command": ["get_property", prop]}) + "\n").encode())
    buf = b""
    while True:
        buf += s.recv(65536)
        for line in buf.split(b"\n"):
            try:
                m = json.loads(line)
            except Exception:
                continue
            if "error" in m and "event" not in m:
                s.close(); return m.get("data")
if __name__ == "__main__":
    for p in sys.argv[1:]:
        v = q(p)
        if p == "playlist":
            v = [(e["filename"].split("/")[-1] + ("*" if e.get("current") else "")) for e in v]
        print(p, "=", v)
