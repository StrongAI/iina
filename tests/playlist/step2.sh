source /Users/admin/Projects/iina-test/lib.sh
R=$MEDIA/review; L=$MEDIA/long
st() { echo "$1: $(ipc path pause | sed "s#.*/##" | tr "\n" " ")"; }
quit_iina; open_file $R/clip01.mp4; sleep 3; out=""
for i in 2 3 4 5 6 7 8; do menu Playback "Next Media"; sleep 1.5; out="$out $(ipc path pause | sed "s#.*/##;s/pause = //" | tr "\n" ":")"; done; echo "T1-steps:$out"
menu Playback "Next Media"; sleep 1.5; st T3-boundary-at-last
echo "T3-log: $(grep -c "Not playing next entry" "$(lastlog)") resumes=$(grep -c "Resuming playback now that file has been loaded" "$(lastlog)")"
quit_iina; open_file $L/long01.mp4; sleep 3
osascript -e "tell application \"IINA\" to activate" -e "delay 0.5" -e "tell application \"System Events\"
key code 124 using command down
key code 49
end tell"; sleep 3; st T2-hold
echo "T2-log:"; grep -E "Pausing playback|Resuming playback|State changed|File started|File loaded" "$(lastlog)" | tail -8 | sed -E "s/^[^ ]+ //" | cut -c1-110
menu Playback "Resume"; sleep 1; st T2-after-resume
quit_iina
