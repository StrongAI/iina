source /Users/admin/Projects/iina-test/lib.sh
for i in 1 2 3 4 5 6 7 8 9 10; do
  quit_iina; rm -rf /Users/admin/Library/Caches/com.colliderli.iina/thumb_cache 2>/dev/null
  open_file $MEDIA/long/long01.mp4; sleep 1.0; menu Playback "Next Media"; sleep 5
  python3 /Users/admin/Projects/iina-test/thumbcancel.py "$(lastlog)" "run $i:"
done; quit_iina
