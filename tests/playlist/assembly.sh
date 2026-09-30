source /Users/admin/Projects/iina-test/lib.sh
R=$MEDIA/review; B=$MEDIA/many
echo "--- precedence: open the fourth of eight clips"
quit_iina; open_file $R/clip04.mp4; sleep 3; ipc playlist
grep -E "Run command: loadfile" "$(lastlog)" | sed -E "s#^([0-9:.]+) .*/(clip[0-9]+)\.mp4 ?(.*)#\2[\3]@\1#" | tr "\n" " "; echo
echo "--- completeness: step while a large folder is being assembled"
quit_iina; python3 /Users/admin/Projects/iina-test/assembly.py $B "$1" $APP
quit_iina
