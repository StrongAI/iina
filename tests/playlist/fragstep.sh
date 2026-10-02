# usage: fragstep.sh <open|away> <wait-seconds> <rounds>
# Steps from one fragmented MP4 that ends in an mfra index to another and records the step times.
# Each run opens a.mp4 of a folder of $MEDIA/fragstep (built by fragstep_media.sh), waits until its
# playback has started and the playlist holds b.mp4, then <wait-seconds> more, steps to b.mp4 with the
# Next Media menu command and reads the log with fragstats.py.
#   open: the folders t01, t34 and t62, each once a round in turn: a 1-minute file stepped to a 1-, 34-
#         or 62-minute one. b.mp4 reaches the playlist through the folder playlist.
#   away: the folders a01 and a62, each once a round in turn: a 1- or 62-minute file stepped to a
#         1-minute one, with thumbnails off so that the two differ only in the file left. b.mp4 is
#         appended over mpv IPC as soon as a.mp4 is opened, with the loadfile command the folder
#         playlist uses, so that a step right after playback starts can come while the full length of
#         a.mp4 is still being worked out.
# A run whose menu click did not produce a step is repeated once and its row is kept, marked NA.
D=$(cd "$(dirname "$0")" && pwd); source $D/lib.sh
MODE=$1; W=$2; N=$3; F=$MEDIA/fragstep
OUT=$D/results/fragstep-$MODE-$W.txt; mkdir -p $D/results; : > $OUT
if [ "$MODE" = away ]; then
  FOLDERS=(a01 a62)
  defaults write com.colliderli.iina enableThumbnailPreview -bool false
else
  FOLDERS=(t01 t34 t62)
fi
once() { # folder
  quit_iina; rm -rf $HOME/Library/Caches/com.colliderli.iina/thumb_cache 2>/dev/null
  open_file $F/$1/a.mp4
  [ "$MODE" = away ] && python3 $D/cmd.py loadfile "$F/$1/b.mp4" append >/dev/null
  python3 $D/waitlog.py "$(lastlog)" "Resuming playback now that file has been loaded" 20
  for _i in $(seq 1 100); do ipc playlist-count | grep -q "= [2-9]" && break; sleep 0.1; done
  sleep $W; menu Playback "Next Media"; sleep 7
  landed=no; ipc path | grep -q "$1/b.mp4" && landed=yes
  python3 $D/fragstats.py "$(dirname "$(lastlog)")" | sed "s#^#folder=$1 landed=$landed #" | tee -a $OUT
}
run() { once $1 | grep -q "total=NA" && once $1 >/dev/null; }
K=${#FOLDERS[@]}
for i in $(seq 1 $N); do
  for j in $(seq 0 $((K - 1))); do run ${FOLDERS[$(( (i + j) % K ))]}; done
done
quit_iina
[ "$MODE" = away ] && defaults delete com.colliderli.iina enableThumbnailPreview 2>/dev/null
echo DONE >> $OUT
