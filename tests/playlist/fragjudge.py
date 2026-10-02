# usage: fragjudge.py <results-file> <margin-ms> <long-folder> <short-folder> <field>...
# Non-inferiority of the runs of fragstep.sh in <long-folder> against those in <short-folder>, judged as
# noninf.py judges a setting on against off: the null hypothesis is that the runs in <long-folder> take
# at least <margin-ms> longer, and an exact one-sided Mann-Whitney test rejects it when p is below 0.05.
# Runs whose command produced no step, or whose step did not land on b.mp4, are left out; a field
# missing from a run counts as infinitely long. A run in a62 is kept only when its step was given while
# the full-length work of the file left was still running (left_length_before_step=none).
import re, sys, statistics
from mwu_core import p_greater
path, margin, long_f, short_f, fields = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5:]
rows = [l for l in open(path) if "step_started=" in l and "step_started=NA" not in l and "landed=yes" in l]
folder = lambda l: re.search(r"folder=(\S+)", l).group(1)
kept = lambda l: folder(l) != "a62" or "left_length_before_step=none" in l
def sample(name, field):
    out = []
    for l in rows:
        if folder(l) == name and kept(l):
            v = re.search(r"%s=(\S+)" % field, l).group(1)
            out.append(float("inf") if v == "NA" else float(v))
    return out
for field in fields:
    lo, sh = sample(long_f, field), sample(short_f, field)
    p = p_greater(sh, [v - margin for v in lo])
    print("%s: %s n=%d median %g, %s n=%d median %g, margin=%g ms p=%.4f %s" % (
        field, long_f, len(lo), statistics.median(lo), short_f, len(sh), statistics.median(sh), margin, p,
        "NON-INFERIOR" if p < 0.05 else "NOT SHOWN"))
