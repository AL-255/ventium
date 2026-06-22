#!/usr/bin/env python3
# Diff the GLS netlist committed cs:eip retire stream (PCTRACE lines) against the
# Verilator golden .vtrace (pc/cs per retire). Reports the first divergence.
import json, re, sys

gls_log = sys.argv[1]
golden_vtrace = sys.argv[2]

# 1. golden: list of (cs, eip) per retire, 0-based n.
golden = []
with open(golden_vtrace) as f:
    for line in f:
        line = line.strip()
        if not line or '"n"' not in line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if 'pc' not in r or 'cs' not in r:
            continue
        eip = int(r['pc'], 16) & 0xFFFFFFFF
        cs = int(r['cs'], 16) & 0xFFFF
        golden.append((cs, eip))

# 2. GLS: PCTRACE n cs eip  (n is the tb's 0-based dbg_retired-1)
# Anchor full 8-hex eip + 4-hex cs to a line end so a half-written last line
# (the xsim log is appended live) is skipped, not treated as a divergence.
pat = re.compile(r'^PCTRACE\s+(\d+)\s+([0-9a-fA-F]{1,4})\s+([0-9a-fA-F]{8})\s*$')
gls = []
with open(gls_log) as f:
    for line in f:
        m = pat.match(line)
        if not m:
            continue
        n = int(m.group(1))
        cs = int(m.group(2), 16) & 0xFFFF
        eip = int(m.group(3), 16) & 0xFFFFFFFF
        gls.append((n, cs, eip))

print(f"golden retires: {len(golden)}")
print(f"gls retires   : {len(gls)} (n range {gls[0][0]}..{gls[-1][0]})" if gls else "gls retires   : 0")

if not gls:
    print("NO GLS PCTRACE LINES YET")
    sys.exit(0)

# The GLS dbg_eip tap and the golden 'pc' may differ by a phase convention
# (post-commit-next-EIP vs fetched-PC). Auto-detect the alignment offset by
# trying to match the GLS stream against the golden at offsets -1,0,+1.
def score(off, k=200):
    hit = 0
    for i, (n, cs, eip) in enumerate(gls[:k]):
        gi = n + off
        if 0 <= gi < len(golden):
            if golden[gi] == (cs, eip):
                hit += 1
    return hit

best_off, best = 0, -1
for off in (-1, 0, 1, 2):
    s = score(off)
    if s > best:
        best, best_off = s, off
print(f"best alignment offset = {best_off} (matched {best}/min(200,len))")

# Diff with the best offset; report first divergence.
first_div = None
matched = 0
for (n, cs, eip) in gls:
    gi = n + best_off
    if gi < 0 or gi >= len(golden):
        print(f"GLS retire n={n} maps to golden index {gi} which is out of range "
              f"(golden has {len(golden)}); GLS ran past golden depth.")
        break
    if golden[gi] == (cs, eip):
        matched += 1
    else:
        first_div = (n, gi, (cs, eip), golden[gi])
        break

if first_div is None:
    print(f"NO DIVERGENCE: GLS netlist committed cs:eip BIT-IDENTICAL to golden "
          f"for all {matched} compared retires (deepest GLS retire n={gls[-1][0]}).")
else:
    n, gi, g, gold = first_div
    print(f"!! FIRST DIVERGENCE at GLS retire n={n} (golden idx {gi}):")
    print(f"     netlist cs:eip = {g[0]:04x}:{g[1]:08x}")
    print(f"     golden  cs:eip = {gold[0]:04x}:{gold[1]:08x}")
    print(f"   (matched {matched} retires bit-identical before divergence)")
    lo = max(0, gi - 4)
    print(f"   golden context [idx {lo}..{gi+1}]:")
    for j in range(lo, min(gi + 2, len(golden))):
        mark = " <-- DIVERGE" if j == gi else ""
        print(f"     [{j}] {golden[j][0]:04x}:{golden[j][1]:08x}{mark}")
