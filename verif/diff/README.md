# `verif/diff/` — `.vtrace` Contract & Differential Comparator (Consumer)

`verif/diff/` owns the canonical trace parser/emitter and the differential comparator used across `make verify`, `make verify-sys`, `make bus-sva`, `verif/fpu87/`, and directed core gates (`docs/trace-format.md`).

| File | Role |
| --- | --- |
| `tracefmt.py` | **Single executable definition of `.vtrace`.** All trace producers (`verif/qemu-trace/gen_trace.py`, `verif/tb/dpi_retire.cpp` schema) and consumers (`compare.py`, coverage/audit tools) must format and parse `.vtrace` through `tracefmt.py` — **never emit hand-formatted JSON**. |
| `compare.py` | Aligns golden (`A`) and RTL (`C`) `.vtrace` streams by retire sequence `n` and compares them in `func` or `cycle` mode. |

---

## Usage

```sh
python3 verif/diff/compare.py --mode func|cycle [--all] [--tol-pct P] \
    [--eflags-mask 0xM] [--max-report N] <golden.vtrace> <rtl.vtrace>
```

- **`--mode func`**: Compares per-instruction post-commit architectural state (`A` = QEMU gdbstub golden from `gen_trace.py`, `C` = Verilator RTL trace).
  - **User mode:** `pc`, `eax..edi`, `eflags`, `cs..gs`.
  - **x87 (`x87:true` in both headers):** Adds 80-bit `st0..st7` and `fctrl`, `fstat`, `ftag`, `fiseg`, `fioff`, `foseg`, `fooff`, `fop`.
  - **System mode (`sys:true` in both headers):** Intersects present system registers (`cr0`, `cr2`, `cr3`, `cr4`, plus optional hidden segment bases when emitted by both sides).
- **`--mode cycle`**: Compares `pc` lockstep (`pc` mismatch is a hard control-flow failure, exit `1`), derives per-instruction clock deltas `cyc[n] - cyc[n-1]`, checks `--tol-pct` (default `0.0`), and summarizes total cycles, CPI, pairing %, and U/V pipe mix (`A` = `p5trace.so` plugin trace, `C` = RTL `--cycle` trace).

### Exit Codes

| Exit | Verdict |
| ---: | --- |
| `0` | Equivalent under the selected mode and tolerance. |
| `1` | Architectural, control-flow (`pc`), trace-length, or cycle-tolerance divergence. |
| `2` | Malformed `.vtrace`, missing header, or incompatible `mode`. |

---

## Comparison & Masking Discipline

1. **Differential Authority:** Never weaken `EFLAGS_DEFAULT_MASK` (`0x003f7fd5`), add ad-hoc field waivers, filter terminal records, or convert regressions into expected-failure pins.
2. **Architecturally Undefined EFLAGS:** In `func` mode, `compare.py` decodes each record's optional `bytes` field with Capstone (`CS_ARCH_X86`) and masks only the flags that `tracefmt.eflags_undefined_mask(mnemonic)` marks architecturally undefined on Pentium (e.g., `AF/SF/ZF/PF` after `MUL`/`IMUL`, `OF` on multi-bit shifts). If `bytes` or Capstone is absent, the full defined mask is enforced.
3. **Record-Scoped x87 Oracle Masks:** Where pinned QEMU 8.2.2 omits x87 stack-fault responses or `FPREM1` quotient condition codes in canonical `make verify`, test manifests (`verif/tests/*/manifest.json`) may specify **closed `[lo, hi]` record ranges** (`x87_stkflt_fstat_ranges`, `x87_stkflt_fpr_ranges`). Open-ended (`null` upper-bound) ranges are forbidden and mechanically rejected by `make docs-status` (`verif/sys/run-docs-status-gate.sh`).
4. **Dual-Issue `--cycle-func` Traces:** In `--cycle-func` runs (`cycle_mode=1` with functional records), paired U+V retirements share the post-pair register snapshot; group-aware drivers compare state at completed issue-group boundaries while keeping full record counts intact.
5. **Golden-Cache Isolation (`verif/lib/verify_worker.sh`):** Cached functional goldens under `build/golden-cache/` key on source SHA, built ELF SHA, QEMU binary SHA, normalized `VTM_QEMU_GDB_PREEXIT` mode (`.preexit0` vs `.preexit1`), `x87`/`max_insn` settings, and producer/transport hashes (`gen_trace.py`, `owned_gdb.py`, `tracefmt.py`). Cycle workers look up initial `ESP` using that exact functional cache key so observer-mode or binary changes never cross-contaminate cached goldens.

---

## Quick Self-Test

```sh
python3 - <<'PY'
import sys; sys.path.insert(0, "verif/diff")
import tempfile, subprocess, tracefmt as tf

gpr = {k: 0 for k in tf.GPR_KEYS}; gpr["eax"] = 1
seg = {k: 0 for k in tf.SEG_KEYS}; seg.update(cs=0x23, ss=0x2b, ds=0x2b, es=0x2b)
rec = tf.func_record(0, 0x08048000, 0x202, gpr, seg, bytes_="83c001")

with tempfile.NamedTemporaryFile("w", suffix=".vtrace", delete=False) as fa, \
     tempfile.NamedTemporaryFile("w", suffix=".vtrace", delete=False) as fc:
    fa.write(tf.dumps(tf.header("qemu-gdbstub", "func")) + "\n" + tf.dumps(rec) + "\n")
    fc.write(tf.dumps(tf.header("rtl", "func")) + "\n" + tf.dumps(rec) + "\n")
    a_path, c_path = fa.name, fc.name

rc = subprocess.call(["python3", "verif/diff/compare.py", "--mode", "func", a_path, c_path])
assert rc == 0
PY
```
