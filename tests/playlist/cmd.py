import json, socket, sys
# usage: cmd.py <command> <arg>...   sends one mpv IPC command, numbers are sent as numbers
def conv(v):
    try:
        return float(v)
    except ValueError:
        return v
s = socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect("/tmp/iina-mpv.sock")
s.sendall((json.dumps({"command": [sys.argv[1]] + [conv(v) for v in sys.argv[2:]]}) + "\n").encode())
buf = b""
while True:
    buf += s.recv(65536)
    for line in buf.split(b"\n"):
        try:
            m = json.loads(line)
        except Exception:
            continue
        if "error" in m and "event" not in m:
            s.close(); print(m["error"]); sys.exit(0)
