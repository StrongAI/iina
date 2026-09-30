source /Users/admin/Projects/iina-test/lib.sh
cd /Users/admin/Projects/iina-test; R=$MEDIA/review
X=1224; Y=762
cmd() { python3 /Users/admin/Projects/iina-test/cmd.py "$@" >/dev/null 2>&1; }
st() { echo "$(ipc path time-pos pause | sed "s#.*/##" | tr "\n" " ")"; }
seeks() { L="$(lastlog)"; awk "/File started/{c=0} /un command: seek/{c++} END{print c+0}" "$L"; }
res() { sleep 1.5; echo "$1: $(st) seeks-after-last-file-start=$(seeks) file-starts=$(grep -c "File started" "$(lastlog)")   [expect $2]"; }
# start <pauseWhenOpen on|off> <playing|paused> [seconds before the end] : open clip01 in that state
start() {
  quit_iina
  if [ "$1" = on ]; then defaults write com.colliderli.iina pauseWhenOpen -bool true; else defaults delete com.colliderli.iina pauseWhenOpen 2>/dev/null; fi
  open_file $R/clip01.mp4; sleep 2
  if [ "$2" = playing ]; then [ "$1" = on ] && menu Playback "Resume"; else [ "$1" = on ] || menu Playback "Pause"; fi
  sleep 0.5
  D=$(ipc duration | sed "s/.*= //"); cmd set_property time-pos $(python3 -c "print($D - ${3:-2})"); sleep 0.4
}
arrow() { osascript -e "tell application \"IINA\" to activate" -e "delay 0.5" -e "tell application \"System Events\" to key code 124"; }
start on playing;  ./gesture $X $Y wheel:-1:3:30;  res W1-wheel-playing-pauseWhenOpen "clip02 pause=False seeks=0"
start off playing; ./gesture $X $Y wheel:-1:15:40; res W2-wheel-burst-playing "clip02 pause=False seeks=0 time-pos<3"
sleep 1; ./gesture $X $Y wheel:-1:1:30; res W4-wheel-again-after-burst "clip02 pause=False seeks=1"
start on paused;   ./gesture $X $Y wheel:-1:3:30;  res W3-wheel-paused-pauseWhenOpen "clip02 pause=True seeks=0"
start off paused;  ./gesture $X $Y wheel:-1:3:30;  res W5-wheel-paused "clip02 pause=True seeks=0"
start on playing 1;  ./gesture $X $Y begin:-20 end; res E1-early-lift-pauseWhenOpen "clip02 pause=False seeks=0"
start off playing 1; ./gesture $X $Y begin:-20 end; res E2-early-lift "clip02 pause=False seeks=0"
for s in on off; do
  start $s playing; ./gesture $X $Y begin:-20 move:-20:3:16 sleep:3000 end & sleep 1.8
  echo "D-drag-hold-pauseWhenOpen-$s before lift: $(st)   [expect clip02 pause=True]"; wait
  res "D-drag-hold-pauseWhenOpen-$s after lift" "clip02 pause=False seeks=0"
done
start on playing 1; sleep 2.5; res N1-natural-end-pauseWhenOpen "clip02 pause=True"
start on playing; arrow; res N2-arrow-key-past-end-pauseWhenOpen "clip02 pause=True"
quit_iina; defaults write com.colliderli.iina pauseWhenOpen -bool true; open_file $R/clip01.mp4; sleep 2; menu Playback "Resume"; sleep 0.5
./gesture $X $Y wheel:-1:1:30; sleep 1.2
D=$(ipc duration | sed "s/.*= //"); cmd set_property time-pos $(python3 -c "print($D - 2)"); sleep 0.4
arrow; res N3-arrow-key-past-end-after-wheel-pauseWhenOpen "clip02 pause=True"
start on playing 6; ./gesture $X $Y wheel:-1:1:30; sleep 4.5; res N4-natural-end-after-wheel-pauseWhenOpen "clip02 pause=True"
defaults write com.colliderli.iina useExactSeek -int 1
start on playing;  ./gesture $X $Y wheel:-1:3:30;  res W6-wheel-playing-pauseWhenOpen-exact "clip02 pause=False seeks=0"
start on playing 1;  ./gesture $X $Y begin:-20 end; res E3-early-lift-pauseWhenOpen-exact "informational"
defaults delete com.colliderli.iina useExactSeek
quit_iina; defaults delete com.colliderli.iina pauseWhenOpen
