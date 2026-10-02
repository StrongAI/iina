# Builds the 10000-file folder the folder-assembly completeness case opens: hard links to the eight review clips.
import os, shutil
M = "/Users/asher/Projects/TestMedia-iina"; d = M + "/many"
shutil.rmtree(d, ignore_errors=True); os.mkdir(d)
for i in range(1, 10001):
    os.link("%s/review/clip0%d.mp4" % (M, (i % 8) + 1), "%s/m%05d.mp4" % (d, i))
print("files in many:", len(os.listdir(d)))
