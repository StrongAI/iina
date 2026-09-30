source /Users/admin/Projects/iina-test/lib.sh
L=$MEDIA/long
quit_iina; rm -rf "/Users/admin/Library/Caches/com.colliderli.iina/thumb_cache"/* 2>/dev/null
open_file $L/long01.mp4; sleep 0.6; menu Playback "Next Media"; sleep 5
grep -E "Getting thumbnails|Resuming playback|Pausing playback before playing|Got new thumbnails|Got all thumbnails|File started" "$(lastlog)" | sed -E "s/\[player0\]\[d\] //;s/Got new thumbnails, progress/progress/" | awk "{t=\$1; \$1=\"\"; printf \"%s%s | \", substr(t,7), \$0} END{print \"\"}" | cut -c1-900
quit_iina
