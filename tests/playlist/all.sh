cd /Users/admin/Projects/iina-test
bash timing3.sh cache 1.5 30 append > /dev/null 2>&1
bash timing3.sh cache 8 8 > /dev/null 2>&1
bash timing3.sh thumbs 1.5 12 > /dev/null 2>&1
bash cacheconf.sh > results/cacheconf.txt 2>&1
bash thumbcancel.sh > results/thumbcancel.txt 2>&1
echo ALLDONE > results/all.done
