source /Users/admin/Projects/iina-test/lib.sh
cd /Users/admin/Projects/iina-test; R=$MEDIA/review
res() { sleep 1.5; L="$(lastlog)"; n=$(awk "/File started/{c=0} /un command: seek/{c++} END{print c+0}" "$L"); echo "$1: $(ipc path time-pos pause | sed "s#.*/##" | tr "\n" " ") seeks-after-last-file-start=$n file-starts=$(grep -c "File started" "$L")"; }
quit_iina; open_file $R/clip01.mp4; sleep 2
./scroll 1224 762 -20 40 20 16; res S1-playing-cross-in-drag
quit_iina; open_file $R/clip01.mp4; sleep 2; menu Playback "Pause"; sleep 0.5
./scroll 1224 762 -20 40 20 16; res S2-paused-cross-in-drag
quit_iina; open_file $R/clip01.mp4; sleep 2
./scroll 1224 762 -20 4 40 16; res S3-playing-cross-in-momentum
quit_iina; defaults write com.colliderli.iina pauseWhenOpen -bool true; open_file $R/clip01.mp4; sleep 2; menu Playback "Resume"; sleep 0.5
./scroll 1224 762 -20 4 40 16; res S4-pauseWhenOpen-cross-in-momentum
quit_iina; open_file $R/clip01.mp4; sleep 2; menu Playback "Resume"; sleep 0.5
./scroll 1224 762 -20 40 0 16; res S5-pauseWhenOpen-cross-in-drag
quit_iina; defaults delete com.colliderli.iina pauseWhenOpen
