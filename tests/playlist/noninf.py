# usage: noninf.py <results-file> <margin-ms> <field>...
# Non-inferiority of the setting on against off, for each timing field of the rows timing3.sh writes:
# the null hypothesis is that runs with the setting on take at least <margin-ms> longer than runs with
# it off. An exact one-sided Mann-Whitney test of the off times against the on times shifted down by
# the margin rejects it when p is below 0.05, which shows the setting delays the field by less than
# the margin. Runs whose command produced no step are left out; a field missing from a run counts as
# infinitely long.
import re, sys
from mwu_core import p_greater
path, margin, fields = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
rows = [l for l in open(path) if "step_started=" in l and "step_started=NA" not in l]
cond_of = lambda l: re.search(r"(?:cache|thumbs)=(on|off)", l).group(1)
def sample(cond, field):
    out = []
    for l in rows:
        if cond_of(l) == cond:
            v = re.search(r"%s=(\S+)" % field, l).group(1)
            out.append(float("inf") if v == "NA" else float(v))
    return out
for field in fields:
    on, off = sample("on", field), sample("off", field)
    p = p_greater(off, [v - margin for v in on])
    print("%s: on n=%d off n=%d margin=%g ms p=%.4f %s" % (
        field, len(on), len(off), margin, p, "NON-INFERIOR" if p < 0.05 else "NOT SHOWN"))
