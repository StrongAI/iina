source /Users/admin/Projects/iina-test/lib.sh
L=$MEDIA/long
run() { # label wait
  quit_iina; rm -rf "/Users/admin/Library/Caches/com.colliderli.iina/thumb_cache"/* 2>/dev/null
  open_file $L/long01.mp4; sleep $2; menu Playback "Next Media"; sleep 4
  python3 - "$(lastlog)" "$1" <<"PY"
import sys, re
def t(s):
    h, m, r = s.split(":"); return (int(h) * 3600 + int(m) * 60 + float(r)) * 1000
step = started = resumed = None
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"(\d\d:\d\d:\d\d\.\d+) ", line)
    if not m: continue
    if "Pausing playback before playing next" in line: step = t(m.group(1)); started = resumed = None
    elif step and started is None and "File started" in line: started = t(m.group(1))
    elif step and started and resumed is None and "Resuming playback now" in line: resumed = t(m.group(1))
print("%s: step->fileStarted %4.0f ms, fileStarted->playing %4.0f ms" % (sys.argv[2], started - step, resumed - started))
PY
}
for i in 1 2 3 4 5 6 7 8; do for th in false true; do defaults write com.colliderli.iina enableThumbnailPreview -bool $th; run "thumbs=$th" 1.5; done; done
defaults delete com.colliderli.iina enableThumbnailPreview; quit_iina
