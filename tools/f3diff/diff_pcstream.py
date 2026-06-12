#!/usr/bin/env python3
"""diff_pcstream.py — QEMU free-run PC-set differential for the F3 FreeDOS stall.

Builds the set Q of all distinct guest linear PCs qemu executed (from the
compact PC-per-line stream produced by capture_qemu_pcs.sh), then walks the
RTL retire window and finds the FIRST record beginning a run of >=MIN_RUN
consecutive retires whose linear PC qemu never executed.

Inputs (parameterize at top):
  QEMU_PCS : one 8-hex-digit linear PC per line, qemu execution order.
  RTL_WIN  : "n cs(hex4) pc(hex8) esp(hex8) ss(hex4) pe" per line, ascending n.
             (pre-extracted from the .vtrace; see the README header of
              capture_qemu_pcs.sh / the extraction snippet in tools/f3diff)

Linear-PC rule for RTL records (matches the SoC address map):
  if cr0.PE==1 and cs in FLAT_SELS: linear = pc          (flat protected mode)
  else:                             linear = (cs<<4 + pc) & 0xFFFFF
A record is a "hit" if its linear is in Q; an unmasked (cs<<4+pc) fallback is
also checked (HMA safety) and counted separately if it rescues a record.
"""
import os
import re
import sys

QEMU_PCS = sys.argv[1] if len(sys.argv) > 1 else "/tmp/f3diff_qemu_pcs.txt"
RTL_WIN  = sys.argv[2] if len(sys.argv) > 2 else "/tmp/f3diff_rtl_window.txt"
VTRACE   = sys.argv[3] if len(sys.argv) > 3 else "/tmp/fdos.vtrace"
N_LO, N_HI = 5_400_000, 6_844_525
MIN_RUN  = 8           # >= this many consecutive not-in-Q retires = divergence
CTX_BEFORE, CTX_AFTER = 64, 16
FLAT_SELS = {0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38}

# ---- 0. extract the RTL window from the vtrace if not already done -----------
if not os.path.exists(RTL_WIN):
    print(f"extracting {RTL_WIN} from {VTRACE} (streamed, n>={N_LO}) ...")
    pat = re.compile(r'"n":(\d+),"pc":"0x([0-9a-f]+)".*?"esp":"0x([0-9a-f]+)"'
                     r'.*?"cs":"0x([0-9a-f]+)","ss":"0x([0-9a-f]+)"'
                     r'.*?"cr0":"0x([0-9a-f]+)"')
    with open(VTRACE) as f, open(RTL_WIN, "w") as out:
        for line in f:
            m = pat.search(line)
            if not m:
                continue
            n = int(m.group(1))
            if n < N_LO:
                continue
            out.write(f"{n} {int(m.group(4),16):04x} {int(m.group(2),16):08x} "
                      f"{int(m.group(3),16):08x} {int(m.group(5),16):04x} "
                      f"{int(m.group(6),16)&1}\n")

# ---- 1. build Q --------------------------------------------------------------
Q = set()
nq = 0
with open(QEMU_PCS) as f:
    while True:
        chunk = f.readlines(1 << 24)
        if not chunk:
            break
        nq += len(chunk)
        Q.update(chunk)
Q = {int(s, 16) for s in Q}
print(f"qemu stream: {nq} PC entries, {len(Q)} unique linear PCs")
print(f"sanity: 0x7c00 in Q = {0x7c00 in Q}; 0xc4ee in Q = {0xc4ee in Q} (must be False)")
assert 0x7c00 in Q, "0x7c00 missing from Q - linear extraction wrong"
assert 0xc4ee not in Q, "0xc4ee unexpectedly in Q"

# ---- 2. walk RTL window ------------------------------------------------------
recs = []          # (n, cs, pc, esp, lin, hit)
with open(RTL_WIN) as f:
    for line in f:
        p = line.split()
        n = int(p[0])
        if n < N_LO or n > N_HI:
            continue
        cs, pc, esp, pe = int(p[1], 16), int(p[2], 16), int(p[3], 16), int(p[5])
        if pe and cs in FLAT_SELS:
            lin = pc
        else:
            lin = ((cs << 4) + pc) & 0xFFFFF
        hit = lin in Q
        rescued = False
        if not hit:                       # HMA / >1MB fallback
            lin_un = (cs << 4) + pc
            if lin_un in Q:
                hit, rescued = True, True
        recs.append((n, cs, pc, esp, lin, hit, rescued))

print(f"RTL window: {len(recs)} records  n=[{recs[0][0]}..{recs[-1][0]}]")
print(f"unmasked-fallback rescues: {sum(r[6] for r in recs)}")

# ---- 3. find first >=MIN_RUN consecutive-miss run ----------------------------
div_i = None
iso_runs = []      # isolated (short) miss runs skipped
i = 0
while i < len(recs):
    if recs[i][5]:
        i += 1
        continue
    j = i
    while j < len(recs) and not recs[j][5]:
        j += 1
    if j - i >= MIN_RUN:
        div_i = i
        break
    iso_runs.append((recs[i][0], j - i, recs[i][4]))
    i = j

print(f"isolated miss-runs (<{MIN_RUN}) skipped before divergence: {len(iso_runs)}")
for n0, ln, lin in iso_runs[:10]:
    print(f"   n={n0} len={ln} lin={lin:#07x}")

if div_i is None:
    print("NO DIVERGENCE FOUND (no run of >=MIN_RUN consecutive misses)")
    sys.exit(1)

dn, dcs, dpc, desp, dlin, _, _ = recs[div_i]
print(f"\nDIVERGENCE: n={dn}  cs:ip={dcs:04x}:{dpc:04x}  lin={dlin:#07x}  esp={desp:#x}")

lo = max(0, div_i - CTX_BEFORE)
hi = min(len(recs), div_i + CTX_AFTER + 1)
print(f"\n--- window [{CTX_BEFORE} before .. {CTX_AFTER} after] ---")
print("      n      cs:ip       lin      esp     inQ")
for k in range(lo, hi):
    n, cs, pc, esp, lin, hit, resc = recs[k]
    mark = "<= DIVERGENCE" if k == div_i else ""
    print(f"{n:9d}  {cs:04x}:{pc:04x}  {lin:07x}  {esp:08x}  {'Y' if hit else 'n'}"
          f"{'(hma)' if resc else ''} {mark}")

# last in-Q record before divergence
for k in range(div_i - 1, -1, -1):
    if recs[k][5]:
        n, cs, pc, esp, lin, _, _ = recs[k]
        print(f"\nLAST in-Q record: n={n}  cs:ip={cs:04x}:{pc:04x}  lin={lin:#07x}  esp={esp:#x}")
        break
