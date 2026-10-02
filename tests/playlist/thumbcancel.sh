# usage: thumbcancel.sh [delay]
# Opens long01.mp4, waits until the folder playlist holds the next entry and the thumbnail scan of
# long01 has begun, steps to long02 <delay> seconds (0.3 by default) after the scan began and judges
# each of ten runs with thumbcancel.py.
source /Users/admin/Projects/iina-test/lib.sh
for i in 1 2 3 4 5 6 7 8 9 10; do
  quit_iina; rm -rf /Users/admin/Library/Caches/com.colliderli.iina/thumb_cache 2>/dev/null
  open_file $MEDIA/long/long01.mp4
  for _i in $(seq 1 100); do ipc playlist-count | grep -q "= [2-9]" && break; sleep 0.1; done
  python3 /Users/admin/Projects/iina-test/waitlog.py "$(lastlog)" "Getting thumbnails" 20
  sleep ${1:-0.3}; menu Playback "Next Media"; sleep 5
  python3 /Users/admin/Projects/iina-test/thumbcancel.py "$(lastlog)" "run $i:"
done; quit_iina
