# `verif/diff` — the differential trace comparator (Consumer)

This directory holds the **Consumer** side of the Ventium differential-testing
stack (see [`../../PLAN.md`](../../PLAN.md) §4.3 and
[`../../docs/trace-format.md`](../../docs/trace-format.md) §3):

| file | role |
|---|---|
| `tracefmt.py` | shared `.vtrace` parser/emitter — the executable definition of the format. **Owned by the format; imported, never duplicated.** |
| `compare.py`  | the comparator: reads two `.vtrace` files and diffs them in `func` or `cycle` mode. |
| `README.md`   | this file. |

`compare.py` only ever *imports* `tracefmt.py`; field names, hex formatting and
the EFLAGS mask tables all come from there so producer and consumer never drift.

---

## Usage

```
compare.py --mode func|cycle [--all] [--tol-pct P] [--eflags-mask 0xM]
           [--max-report N] <A.vtrace> <C.vtrace>
```

Per the spec, `A` is always the **golden** trace and `C` is the **device under
test (RTL)**:

- **`--mode func`** — `A` = QEMU **gdbstub** golden, `C` = RTL.
- **`--mode cycle`** — `A` = QEMU **plugin** golden (`p5model`-derived), `C` = RTL.

### Options
- `--all` — list divergences instead of stopping at the first (capped by
  `--max-report`, default 20).
- `--max-report N` — with `--all`, the maximum number of divergences to print.
- `--tol-pct P` — **cycle mode only**: per-instruction cost tolerance band, in
  percent. Default `0.0` = exact (microbench gates). Loosen for whole
  benchmarks (the cycle oracle is itself an estimate — PLAN.md §8).
- `--eflags-mask 0xM` — **func mode only**: override the EFLAGS compare mask.
  Default is `tracefmt.EFLAGS_DEFAULT_MASK` (`0x003f7fd5`).

### Exit status (the machine verdict — `docs/trace-format.md` §3)
| code | meaning |
|---|---|
| `0` | traces equivalent under the selected mode/tolerance |
| `1` | divergence found (incl. length/control-flow mismatch) |
| `2` | malformed input / header-incompatible (wrong mode, no header, missing `cyc`) |

The human-readable summary goes to **stdout**; warnings go to **stderr**. The
verdict lives in the exit code so scripts can gate on it.

---

## What it checks

### Functional mode (`--mode func`)
Records are aligned by `n` (with a cross-check that the sequence numbers agree).
For each pair the fields are compared in the order returned by
`tracefmt.func_compare_keys()`:

```
pc, eax,ecx,edx,ebx,esp,ebp,esi,edi, eflags, cs,ss,ds,es,fs,gs [, x87…]
```

- **EFLAGS masking.** EFLAGS is compared as `(A ^ C) & mask == 0`, where
  `mask = (--eflags-mask or EFLAGS_DEFAULT_MASK) & ~undefined`. The
  `undefined` part comes from `tracefmt.eflags_undefined_mask(mnemonic)` — the
  flags an instruction leaves *architecturally undefined* (e.g. `IMUL` leaves
  AF/SF/ZF/PF undefined). The mnemonic is recovered by decoding the record's
  `bytes` field with **capstone** (CS_ARCH_X86 / CS_MODE_32). If `bytes` is
  absent or capstone is unavailable, the full mask is used.
- **x87.** x87 fields are compared **only when both headers declare `x87:true`**.
  If exactly one does, the comparator warns and compares the common integer/seg
  fields only.
- **First-divergence report.** Reports `{n, pc, field, expected (A), got (C)}`
  and stops. `--all` lists up to `--max-report` divergences instead.
- **Length mismatch** (one trace shorter) is reported clearly and counts as a
  divergence (exit `1`).

### Cycle mode (`--mode cycle`)
Records are aligned by `n`; `pc` is a sanity check (a `pc` mismatch means the
two runs executed *different* instructions — a control-flow divergence, exit
`1`, regardless of cycle tolerance). Per-instruction cost is derived from the
cumulative counter as `cyc[n] - cyc[n-1]` for both sides. The comparator:

- compares **total cycles** A vs C and the **% diff**,
- flags **per-instruction deltas beyond `--tol-pct`**,
- prints an aggregate summary: total cycles, overall **CPI**, **pairing%** and
  **pipe mix** (from records that carry `pipe`/`paired`), and the count of
  out-of-tolerance instructions.

---

## Self-test / examples

There is no separate test harness file; the fixtures are tiny and synthesized
on the fly with `tracefmt`. To reproduce the self-tests:

```sh
cd verif/diff
python3 - <<'PY'
import tracefmt as tf
def gpr(**k): b={x:0 for x in tf.GPR_KEYS}; b.update(k); return b
def seg(**k): b={x:0 for x in tf.SEG_KEYS}; b.update(k); return b
def w(p,h,rs):
    with open(p,"w") as f:
        f.write(tf.dumps(h)+"\n")
        for r in rs: f.write(tf.dumps(r)+"\n")

recs=[tf.func_record(i,0x8048000+3*i,0x202,gpr(eax=i),
                     seg(cs=0x23,ss=0x2b,ds=0x2b,es=0x2b),bytes_="83c001")
      for i in range(3)]
w("/tmp/a.vtrace", tf.header("qemu-gdbstub","func"), recs)
w("/tmp/c_same.vtrace", tf.header("rtl","func"), recs)
div=[dict(r) for r in recs]; div[1]=dict(div[1]); div[1]["ecx"]=tf.h32(0xdead)
w("/tmp/c_div.vtrace", tf.header("rtl","func"), div)
PY

python3 compare.py --mode func /tmp/a.vtrace /tmp/c_same.vtrace ; echo "exit=$?"  # -> 0
python3 compare.py --mode func /tmp/a.vtrace /tmp/c_div.vtrace  ; echo "exit=$?"  # -> 1, n=1 ecx
```

The self-test matrix that was run to validate this component:

1. func identical pair -> exit `0`.
2. func single-field divergence at `n=1` (`ecx`) -> exit `1`, reports exactly
   `n=1 field=ecx`.
3. cycle identical pair -> exit `0`.
4. cycle per-instruction cost divergence at `n=2` (tol 0) -> exit `1`.
5. malformed (no header) -> exit `2`.
6. mode mismatch (cycle file fed to `--mode func`) -> exit `2`.
7. producer mismatch -> **warning only**, still exits on the data verdict.
8. length mismatch (A=3, C=2) -> exit `1`, reported clearly.
9. x87 header mismatch -> warns, compares common fields, exit per data.
10. `IMUL` with a differing **undefined** ZF -> tolerated (exit `0`); the same
    ZF difference under `ADD` (ZF **defined**) -> exit `1`. (capstone masking.)
11. `--all` / `--max-report`, `--eflags-mask 0x0`, `--tol-pct` loose band — all
    behave as specified.

---

## Integration notes

- **Import path.** `compare.py` inserts its own directory on `sys.path`, so it
  imports the sibling `tracefmt.py` regardless of the caller's CWD. It can be
  run from anywhere as `python3 verif/diff/compare.py …`.
- **capstone is optional at runtime.** It is used purely for EFLAGS
  undefined-flag masking via the `bytes` field. If it is missing the comparator
  still runs and just uses the full EFLAGS mask (a stricter, never-wrong-but-
  occasionally-noisy compare). capstone 5.0.7 is present in this environment.
- **M0 expectation.** At M0 the RTL is a NOP stub, so `func` mode is *expected*
  to report a divergence. The gate is that the comparator runs end-to-end and
  reports a **coherent** first divergence (correct `n`/`field`, sensible
  expected-vs-got) — see `docs/trace-format.md` §4. Real agreement begins at M1.
- **Producers must align by `n` in retire order.** The comparator pairs records
  positionally and cross-checks `n`; producers that drop/reorder/duplicate
  records will be flagged (func: an `n` field divergence; cycle: a retire-order
  note that forces a `1` verdict).
