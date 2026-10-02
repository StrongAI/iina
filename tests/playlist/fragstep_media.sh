# Builds the folders fragstep.sh opens, in $MEDIA/fragstep, from the fragmented MP4s in $MEDIA/frag.
# Each folder holds the file opened, a.mp4, and the file stepped to, b.mp4. The 1-minute file stepped
# to is a copy, so that it is not the file opened; every other file is a hard link.
D=$(cd "$(dirname "$0")" && pwd); source $D/lib.sh
S=$MEDIA/frag; F=$MEDIA/fragstep
rm -rf $F; mkdir -p $F/t01 $F/t34 $F/t62 $F/a01 $F/a62
cp $S/frag-01m.mp4 $F/one.mp4
for d in t01 t34 t62 a01; do ln $S/frag-01m.mp4 $F/$d/a.mp4; done
ln $S/frag-62m.mp4 $F/a62/a.mp4
for d in t01 a01 a62; do ln $F/one.mp4 $F/$d/b.mp4; done
ln $S/frag-34m.mp4 $F/t34/b.mp4; ln $S/frag-62m.mp4 $F/t62/b.mp4
ls -li $F/*/
