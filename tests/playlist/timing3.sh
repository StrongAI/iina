# usage: timing3.sh <cache|thumbs> <wait-seconds> <rounds> [append]
# Alternates the named setting on and off; each run opens long01, waits, steps to the next entry and reads the logs.
# A run whose menu click did not produce a step is repeated once and its row is kept, marked NA.
source /Users/admin/Projects/iina-test/lib.sh
L=$MEDIA/long; MODE=$1; W=$2; N=$3
KEY=enableCache; [ "$MODE" = thumbs ] && KEY=enableThumbnailPreview
OUT=/Users/admin/Projects/iina-test/results/$MODE-$W.txt; [ "$4" = append ] || : > $OUT
once() { # on|off
  quit_iina
  [ "$1" = on ] && defaults write com.colliderli.iina $KEY -bool true || defaults write com.colliderli.iina $KEY -bool false
  rm -rf /Users/admin/Library/Caches/com.colliderli.iina/thumb_cache 2>/dev/null
  open_file $L/long01.mp4; sleep $W; menu Playback "Next Media"; sleep 7
  python3 /Users/admin/Projects/iina-test/mpvstats.py $MODE $W "$(dirname "$(lastlog)")" | sed "s/^/asked=$1 /" | tee -a $OUT
}
run() { once $1 | grep -q "total=NA" && once $1 >/dev/null; }
for i in $(seq 1 $N); do if [ $((i % 2)) = 1 ]; then run on; run off; else run off; run on; fi; done
quit_iina; defaults delete com.colliderli.iina $KEY 2>/dev/null; echo DONE >> $OUT
