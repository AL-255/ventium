#!/usr/bin/env python3
"""M7.3a phase 1 — Win95 environment-input PARSER (docs/m7-lockstep-spec.md §M7.3).

Turns the two raw QEMU logs that record.sh emits, into the structured
trace-contract records the next-phase co-sim-bus CONSUMER will inject into the
Ventium RTL. It parses (and does NOT fabricate) only what QEMU's devices/CPU
actually produced on the deterministic replay:

  --int  record-int.log   (-d int)                      -> `intr` records
  --dev  record-devio.log (memory_region_ops_{read,write}) -> `dev_in` + DMA/write records

Output (NDJSON, one record per line) carries the trace-contract fields named in the
spec (§Trace-contract extension):

  intr   : {"kind":"intr",   "vec":<int>, "err":<int|null>, "soft":<bool>,
            "cpl":<int>, "ip":"SEG:OFF", "sp":"SEG:OFF", "seq":<int>}
           (from the seg_helper "v=.. e=.. i=.. cpl=.. IP=.. SP=.." lines —
            authoritative vector + errcode + the instruction boundary)
  hwint  : {"kind":"hwint",  "vec":<int>, "seq":<int>}
           (from "Servicing hardware INT=0xNN" — the async IRQ delivery marker)
  dev_in : {"kind":"dev_in", "addr":<int>, "val":<int>, "size":<int>,
            "region":"<name>", "seq":<int>}
           (from memory_region_ops_read — the PIO/MMIO READ VALUE the CPU consumed)
  dev_wr : {"kind":"dev_wr", "addr":<int>, "val":<int>, "size":<int>,
            "region":"<name>", "seq":<int>}
           (from memory_region_ops_write — a device/DMA write the CPU emitted;
            the consumer does NOT inject these but they pin the bus-side timeline)

Alignment to the single-step trace: each record carries a monotone `seq` (its order
in the recorded timeline). The next-phase consumer aligns these to the RTL's retire
boundaries by replay-icount exactly as the Quake int-0x80 proxy aligns sys_call
effects (same pattern as gen_trace's g-packet recovery). This producer does the
authoritative-capture half only.

M7.3a system-replay alignment (--combined):
  The producer gen_trace.py --system-replay routes -d cpu,int,memory_region_ops to
  ONE combined log. Passing that log via --combined here parses it through the SAME
  alignment engine the producer uses (verif/qemu-trace/replaylog.iter_aligned), so
  each env-input record carries `insn` = the single-stepped instruction index it is
  aligned to (the replay-icount boundary), not just a within-stream seq. This is the
  authoritative cross-stream alignment the consumer wants.

USAGE
  # legacy two-log mode (within-stream seq only):
  python3 parse_devlog.py --int build/m7/win95/record-int.log \\
                          --dev build/m7/win95/record-devio.log \\
                          --out build/m7/win95/win95-env.ndjson [--summary]
  # combined-log mode (per-instruction-aligned, M7.3a system-replay):
  python3 parse_devlog.py --combined build/m7/win95/replay-combined.log \\
                          --out build/m7/win95/win95-env.aligned.ndjson [--summary]
"""
import argparse
import json
import os
import re
import sys

# seg_helper.c authoritative interrupt/exception line:
#   "<icount>: v=2a e=0000 i=1 cpl=3 IP=0033:c0001234 pc=00000000 SP=0030:0000fffc env->regs[R_EAX]=..."
RE_VEC = re.compile(
    r'v=(?P<vec>[0-9a-fA-F]+)\s+e=(?P<err>[0-9a-fA-F]+)\s+i=(?P<i>\d+)\s+'
    r'cpl=(?P<cpl>\d+)\s+IP=(?P<ip>[0-9a-fA-F]+:[0-9a-fA-F]+)\s+'
    r'pc=(?P<pc>[0-9a-fA-F]+)\s+SP=(?P<sp>[0-9a-fA-F]+:[0-9a-fA-F]+)'
)
# async hardware IRQ delivery marker:
#   "Servicing hardware INT=0x08"
RE_HWINT = re.compile(r'Servicing hardware INT=0x(?P<vec>[0-9a-fA-F]+)')
# memory_region_ops_{read,write} trace event:
#   "memory_region_ops_read cpu 0 mr 0x.. addr 0x71 value 0x0 size 1 name 'rtc'"
RE_MRO = re.compile(
    r"memory_region_ops_(?P<op>read|write)\s+cpu\s+(?P<cpu>-?\d+)\s+mr\s+0x[0-9a-fA-F]+\s+"
    r"addr\s+0x(?P<addr>[0-9a-fA-F]+)\s+value\s+0x(?P<val>[0-9a-fA-F]+)\s+"
    r"size\s+(?P<size>\d+)\s+name\s+'(?P<name>[^']*)'"
)


def parse_int(path, recs, counts):
    with open(path, 'r', errors='replace') as f:
        for line in f:
            m = RE_VEC.search(line)
            if m:
                soft = (m.group('i') == '1')
                err = int(m.group('err'), 16)
                recs.append({
                    "kind": "intr",
                    "vec": int(m.group('vec'), 16),
                    "err": err if err else None,
                    "soft": soft,
                    "cpl": int(m.group('cpl')),
                    "ip": m.group('ip'),
                    "sp": m.group('sp'),
                })
                counts["intr"] += 1
                continue
            m = RE_HWINT.search(line)
            if m:
                recs.append({"kind": "hwint", "vec": int(m.group('vec'), 16)})
                counts["hwint"] += 1


def parse_dev(path, recs, counts):
    with open(path, 'r', errors='replace') as f:
        for line in f:
            m = RE_MRO.search(line)
            if not m:
                continue
            kind = "dev_in" if m.group('op') == 'read' else "dev_wr"
            recs.append({
                "kind": kind,
                "cpu": int(m.group('cpu')),
                "addr": int(m.group('addr'), 16),
                "val": int(m.group('val'), 16),
                "size": int(m.group('size')),
                "region": m.group('name'),
            })
            counts[kind] += 1


def parse_combined(path, recs, counts, max_insn=None):
    """Parse the M7.3a combined cpu+int+devio replay log into PER-INSTRUCTION-
    ALIGNED env-input records, using the producer's own alignment engine.

    Each emitted record additionally carries `insn` = the single-stepped
    instruction index (replay-icount boundary) the input is aligned to, plus the
    instruction's `pc`. dev_in/dev_wr keep their {addr,val,size,region} shape;
    intr keeps {vec,err,soft,cpl,ip,sp}; an async-only delivery is `hwint`."""
    # Import the shared alignment engine from the producer dir (sibling tree).
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.normpath(os.path.join(here, "..", "..", "..", "..", ".."))
    qt = os.path.join(repo, "verif", "qemu-trace")
    if qt not in sys.path:
        sys.path.insert(0, qt)
    import replaylog  # noqa: E402

    for insn, rec in enumerate(replaylog.iter_aligned(path, max_insn=max_insn)):
        pc = rec["pre"].eip
        for r in rec["dev_in"]:
            recs.append({"kind": "dev_in", "insn": insn, "pc": pc,
                         "addr": r["addr"], "val": r["val"],
                         "size": r["size"], "region": r["region"]})
            counts["dev_in"] += 1
        for w in rec["dma_wr"]:
            recs.append({"kind": "dev_wr", "insn": insn, "pc": pc,
                         "addr": w["addr"], "val": w["val"],
                         "size": w["size"], "region": w["region"]})
            counts["dev_wr"] += 1
        iv = rec["intr"]
        if iv is not None:
            if iv.get("soft") is None and "cpl" not in iv:
                recs.append({"kind": "hwint", "insn": insn, "pc": pc,
                             "vec": iv["vec"]})
                counts["hwint"] += 1
            else:
                recs.append({"kind": "intr", "insn": insn, "pc": pc,
                             "vec": iv["vec"], "err": iv.get("err") or None,
                             "soft": iv.get("soft"), "cpl": iv.get("cpl"),
                             "ip": iv.get("ip"), "sp": iv.get("sp")})
                counts["intr"] += 1


def main():
    ap = argparse.ArgumentParser(description="Parse Win95 record/replay env-input logs.")
    ap.add_argument('--int', dest='intlog', help='record-int.log (-d int)')
    ap.add_argument('--dev', dest='devlog', help='record-devio.log (memory_region_ops_*)')
    ap.add_argument('--combined', dest='combined',
                    help='combined cpu+int+devio replay log (M7.3a system-replay): '
                         'emits per-instruction-aligned records with an `insn` index.')
    ap.add_argument('--max-insn', type=int, default=None,
                    help='--combined: bound the aligned output to N instructions.')
    ap.add_argument('--out', required=True, help='output NDJSON path')
    ap.add_argument('--summary', action='store_true', help='print a summary to stderr')
    args = ap.parse_args()

    recs = []
    counts = {"intr": 0, "hwint": 0, "dev_in": 0, "dev_wr": 0}
    # NOTE: the two logs are separate QEMU output streams. We keep each stream's
    # internal order (the authoritative within-stream ordering) and tag a global
    # monotone seq after concatenation; the consumer's true cross-stream alignment
    # is by replay-icount in the next phase. Here seq pins within-producer order.
    if args.combined:
        parse_combined(args.combined, recs, counts, max_insn=args.max_insn)
    if args.intlog:
        parse_int(args.intlog, recs, counts)
    if args.devlog:
        parse_dev(args.devlog, recs, counts)

    with open(args.out, 'w') as out:
        for seq, r in enumerate(recs):
            r["seq"] = seq
            out.write(json.dumps(r, separators=(',', ':')) + "\n")

    if args.summary:
        e = sys.stderr
        e.write(f"[parse] total records : {len(recs)}\n")
        for k in ("intr", "hwint", "dev_in", "dev_wr"):
            e.write(f"[parse]   {k:7s}: {counts[k]}\n")
        # distinct interrupt vectors + first device read (evidence the capture is real)
        vecs = sorted({r['vec'] for r in recs if r['kind'] in ('intr', 'hwint')})
        e.write(f"[parse] distinct vectors: {[hex(v) for v in vecs]}\n")
        first_rd = next((r for r in recs if r['kind'] == 'dev_in'), None)
        if first_rd:
            e.write(f"[parse] first dev_in   : addr=0x{first_rd['addr']:x} "
                    f"val=0x{first_rd['val']:x} size={first_rd['size']} "
                    f"region={first_rd['region']!r}\n")
        # top device regions by read volume
        from collections import Counter
        topr = Counter(r['region'] for r in recs if r['kind'] == 'dev_in').most_common(8)
        e.write(f"[parse] top read regions: {topr}\n")

    print(args.out)


if __name__ == '__main__':
    main()
