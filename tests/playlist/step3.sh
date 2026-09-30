# usage: step3.sh <delay-in-seconds>
# Steps to the next entry and gives a pause <delay> later, so that the pause falls in the interval
# in which the player reports paused because of the pause the step itself makes before loading.
# The entry stepped to must stay paused.
source /Users/admin/Projects/iina-test/lib.sh
L=$MEDIA/long
# The "pause when media is opened" setting is at its default, off, so that the file plays when opened.
quit_iina; defaults delete com.colliderli.iina pauseWhenOpen 2>/dev/null; open_file $L/long01.mp4; sleep 3
osascript -e "tell application \"IINA\" to activate" -e "delay 0.5" -e "tell application \"System Events\"
key code 124 using command down
delay $1
key code 49
end tell"; sleep 3
state="$(ipc path pause | sed "s#.*/##" | tr "\n" " ")"
lines="$(grep -E "Pausing playback|Resuming playback|State changed|File started" "$(lastlog)" | tail -8 | sed -E "s/^[^0-9]*//" | cut -c1-110)"
echo "$lines"
# The pause falls in the interval when the line it logs follows the change to paused the step
# causes and precedes the change to starting.
window=$(echo "$lines" | awk '/from playing to paused/ {p=1} p && /(Pausing|Resuming) playback$/ {u=1} /from paused to starting/ {if (u) w=1; p=0} END {print w ? "yes" : "no"}')
case "$state" in *long02.mp4*"pause = True"*) held=yes;; *) held=no;; esac
echo "T4-hold-in-window delay=$1: $state pause-in-window=$window held=$held RESULT=$([ $window = yes ] && [ $held = yes ] && echo PASS || ([ $window = no ] && echo MISSED-WINDOW || echo FAIL))"
quit_iina
