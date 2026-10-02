# usage: waitlog.py <log> <text> <timeout-seconds>
# Returns as soon as a line holding <text> is in the log, reading it every 5 ms; exits 1 on timeout.
import sys, time
path, text, limit = sys.argv[1], sys.argv[2], float(sys.argv[3])
end = time.monotonic() + limit
while time.monotonic() < end:
    try:
        with open(path, errors="replace") as f:
            if text in f.read(): sys.exit(0)
    except OSError:
        pass
    time.sleep(0.005)
sys.exit(1)
