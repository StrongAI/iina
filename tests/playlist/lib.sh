# The directory holding these scripts and the helpers compiled from them.
TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP=/Users/asher/Projects/Deployment/IINA/IINA.app
MEDIA=/Users/asher/Projects/TestMedia-iina
ipc() { python3 $TESTS/ipc.py "$@" 2>&1; }
menu() { $TESTS/axmenu "$1" "$2" >/dev/null 2>&1 || echo "menu click failed: $1 > $2"; }
quit_iina() { $TESTS/axmenu IINA "Quit IINA" >/dev/null 2>&1; for _i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$APP/Contents/MacOS/IINA" >/dev/null || break; sleep 1; done; rm -f /tmp/iina-mpv.sock; }
open_file() { open -a "$APP" "$1"; for _i in $(seq 1 50); do [ -S /tmp/iina-mpv.sock ] && ipc path | grep -q "$(basename "$1")" && break; sleep 0.2; done; }
lastlog() { ls -t /Users/asher/Library/Logs/com.colliderli.iina/*/iina.log 2>/dev/null | head -1; }
# Bring the IINA under test to the front without an Apple event, then press keys through keys.
front() { open -a "$APP"; sleep 0.5; }
keys() { $TESTS/keys "$@"; }
