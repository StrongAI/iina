APP=/Users/admin/Projects/Deployment/IINA/IINA.app
MEDIA=/Users/admin/Projects/TestMedia-iina
ipc() { python3 /Users/admin/Projects/iina-test/ipc.py "$@" 2>&1; }
menu() { osascript -e "tell application \"System Events\" to tell process \"IINA\" to click menu item \"$2\" of menu \"$1\" of menu bar item \"$1\" of menu bar 1" >/dev/null 2>&1 || echo "menu click failed: $1 > $2"; }
quit_iina() { osascript -e "quit app \"IINA\"" 2>/dev/null; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x IINA >/dev/null || break; sleep 1; done; rm -f /tmp/iina-mpv.sock; }
open_file() { open -a "$APP" "$1"; for i in $(seq 1 50); do [ -S /tmp/iina-mpv.sock ] && ipc path | grep -q "$(basename "$1")" && break; sleep 0.2; done; }
lastlog() { ls -t /Users/admin/Library/Logs/com.colliderli.iina/*/iina.log 2>/dev/null | head -1; }
