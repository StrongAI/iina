source "$(dirname "$0")/lib.sh"
R=$MEDIA/review
row() { echo "$1: $(ipc path cache demuxer-max-bytes cache-secs | sed "s#.*/##" | tr "\n" " ")"; }
for mode in default off; do
  if [ $mode = off ]; then defaults write com.colliderli.iina enableCache -bool false; else defaults delete com.colliderli.iina enableCache 2>/dev/null; fi
  echo "--- enableCache $mode; overrides: $(defaults read com.colliderli.iina 2>/dev/null | grep -E "enableCache|defaultCacheSize|secPrefech" | tr -d "\n" || true)"
  quit_iina; open_file $R/clip01.mp4; sleep 2; row open
  for i in 2 3 4 5 6 7 8; do menu Playback "Next Media"; sleep 1.5; row step$i; done
done
defaults delete com.colliderli.iina enableCache 2>/dev/null; quit_iina
