# usage: mwu.py <results-file> <field>...
# For each field: the on and off samples, their medians, and the exact one-sided Mann-Whitney p-value for on > off
# (permutation distribution of the rank sum with mid-ranks for ties, counted exactly by dynamic programming).
# A run with no step (the menu click failed) has no measurement and is left out; the count left out is printed.
import sys, re, statistics
allrows = [l for l in open(sys.argv[1]) if "step_started=" in l]
rows = [l for l in allrows if "step_started=NA" not in l]
cond_of = lambda l: re.search(r"(?:cache|thumbs)=(on|off)", l).group(1)
def sample(cond, field):
    out = []
    for l in rows:
        if cond_of(l) == cond:
            v = re.search(r"%s=(\S+)" % field, l).group(1)
            out.append(float("inf") if v == "NA" else float(v))
    return out
def p_greater(a, b):
    pool = sorted(a + b); rank2 = {}; i = 0
    while i < len(pool):
        j = i
        while j < len(pool) and pool[j] == pool[i]: j += 1
        rank2[pool[i]] = (i + 1) + j; i = j
    obs = sum(rank2[v] for v in a); n = len(a)
    ways = [dict() for _ in range(n + 1)]; ways[0][0] = 1
    for v in a + b:
        r = rank2[v]
        for k in range(n - 1, -1, -1):
            for s, c in list(ways[k].items()):
                ways[k + 1][s + r] = ways[k + 1].get(s + r, 0) + c
    tot = sum(ways[n].values()); ge = sum(c for s, c in ways[n].items() if s >= obs)
    return ge / tot
show = lambda xs: sorted(int(v) if v != float("inf") else 10**9 for v in xs)
print("runs=%d, without a step and left out=%d, asked/logged setting mismatches=%d" % (
    len(allrows), len(allrows) - len(rows), sum(1 for l in allrows if "asked=" in l and re.search(r"asked=(\w+)", l).group(1) != cond_of(l))))
for field in sys.argv[2:]:
    on, off = sample("on", field), sample("off", field)
    print("%s: on n=%d median=%.0f %s | off n=%d median=%.0f %s | one-sided Mann-Whitney p(on>off)=%.3f" % (
        field, len(on), statistics.median(on), show(on), len(off), statistics.median(off), show(off), p_greater(on, off)))
early = sum(int(re.search(r"scans_before_resume=(\d+)", l).group(1)) for l in rows); scans = sum(int(re.search(r"scans=(\d+)", l).group(1)) for l in rows)
print("thumbnail scans started=%d, of which before their entry resumed=%d" % (scans, early))
