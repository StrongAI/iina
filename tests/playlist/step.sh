source /Users/admin/Projects/iina-test/lib.sh
R=$MEDIA/review; L=$MEDIA/long
st() { echo "$1: $(ipc path pause | sed "s#.*/##" | tr "\n" " ")"; }
multi() { local s=""; for m in "$@"; do s="$s click menu item \"$m\" of menu \"Playback\" of menu bar item \"Playback\" of menu bar 1
"; done; osascript -e "tell application \"System Events\" to tell process \"IINA\"
$s
end tell" >/dev/null 2>&1 || echo "multi failed: $*"; }
quit_iina; open_file $R/clip01.mp4; sleep 2; st T1-open
for i in 2 3 4 5 6 7 8; do menu Playback "Next Media"; sleep 1.5; st T1-step$i; done
menu Playback "Next Media"; sleep 1.5; st T3-boundary-at-last
echo "T3-log: $(grep -c "Not playing next entry" "$(lastlog)")"
quit_iina; open_file $R/clip01.mp4; sleep 2
multi "Next Media" "Next Media" "Next Media" "Next Media" "Next Media" "Next Media" "Next Media"; sleep 3; st T1-rapid7
quit_iina; open_file $L/long01.mp4; sleep 3; st T2-open
multi "Next Media" "Pause"; sleep 3; st T2-hold
echo "T2-log:"; grep -E "Pausing playback|Resuming playback|State changed|File started|File loaded" "$(lastlog)" | tail -9 | sed -E "s/^[^ ]+ //" | cut -c1-110
quit_iina; open_file $R/clip04.mp4; multi "Next Media" "Next Media"; sleep 3; st T4-early-steps; ipc playlist
echo "T4-order: $(grep -E "Run command: loadfile" "$(lastlog)" | sed -E "s#.*/(clip[0-9]+)\.mp4 ?#\1 #" | tr "\n" " " | cut -c1-200)"
quit_iina
