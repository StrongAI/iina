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
