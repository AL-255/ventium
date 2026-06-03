# Ventium trace format (v1) — the differential-testing contract

This is the **central interface** of the verification stack (see
[`../PLAN.md`](../PLAN.md) §4). Three producers and one consumer must agree on it:

- **Producer A — functional/architectural trace:** the QEMU **gdbstub** golden
  generator (`verif/qemu-trace/gen_trace.py`). QEMU 8.2.2's *plugin* API cannot
  read register values (that arrived in QEMU 9.0), so architectural state is read
  by single-stepping `qemu-i386 -g <port>` over the GDB Remote Serial Protocol.
- **Producer B — cycle trace:** the QEMU TCG **plugin** (`verif/qemu-plugins/p5trace.c`).
  The plugin *can* see PC, instruction bytes, and memory addresses, so it emits
  retire-order PC + cumulative cycle estimate + pipe/pairing. (Cycle numbers come
  from the same model as `ventium-refs/.../plugin/p5model.c`.)
- **Producer C — RTL trace:** the Verilator C++ testbench (`verif/tb/`), driven
  by the RTL via the DPI retire callback (see [`rtl-interface.md`](rtl-interface.md)).
- **Consumer:** the comparator (`verif/diff/compare.py`), which diffs A-vs-C
  (functional mode) and B-vs-C (cycle mode).

The shared Python parser/emitter is [`../verif/diff/tracefmt.py`](../verif/diff/tracefmt.py)
— treat it as the executable definition of this document.

---

## 1. Container format

**JSON Lines** (`.vtrace`): one JSON object per line, UTF-8, `\n`-terminated.

- The **first line** is a header object identifying the producer and options.
- Every subsequent line is one **retire record** (one committed instruction).
- Records appear in **architectural retire order**, `n` strictly increasing.
- Records are compared by **parsed fields**, not byte-identical text — producers
  need not agree on key order or whitespace, only on field names/values. (A
  canonical pretty form exists in `tracefmt.py` for readable diffs, but the
  comparator never relies on textual identity.)

### Header line
```json
{"vtrace":1,"producer":"qemu-gdbstub|qemu-plugin|rtl","mode":"func|cycle","x87":false,"note":"..."}
```
- `vtrace`: format version, currently `1`.
- `producer`: which of A/B/C wrote this file.
- `mode`: `"func"` (architectural-state records) or `"cycle"` (cycle records).
- `x87`: `true` if `func` records carry x87 fields (§2.2). Default `false`.
- `note`: free-form (binary name, qemu args, git rev…). Ignored by the comparator.

---

## 2. Retire record

### 2.1 Common fields (every record, both modes)
| key | type | meaning |
|---|---|---|
| `n`   | int        | retire sequence number, **0-based**, strictly increasing |
| `pc`  | hex string | virtual address the retired instruction was **fetched** at, e.g. `"0x08048000"` |
| `bytes` | hex string *(optional)* | raw instruction bytes, lowercase, no `0x`, e.g. `"83c001"`. Used for decoder cross-check / human diffs. |

**State convention.** A record describes one instruction. `pc` is *that*
instruction's fetch address. All register fields below are the architectural
state **immediately after that instruction commits** (post-state). Thus the `pc`
of record `n+1` equals the next-EIP produced by record `n` (modulo control flow),
which the comparator may use as a redundant control-flow check.

### 2.2 Functional-mode fields (`mode:"func"`)
Integer/system state (always present in func records):
| key | type | meaning |
|---|---|---|
| `eflags` | hex string (32-bit) | post-commit EFLAGS |
| `eax`,`ecx`,`edx`,`ebx`,`esp`,`ebp`,`esi`,`edi` | hex string (32-bit) | post-commit GPRs |
| `cs`,`ss`,`ds`,`es`,`fs`,`gs` | hex string (16-bit) | post-commit segment selectors |
| `exc` | int or `null` *(optional)* | fault/exception vector this instruction raised, else absent/`null` |

x87 state (present only when header `x87:true`):
| key | type | meaning |
|---|---|---|
| `st0`..`st7` | hex string (80-bit, 20 hex digits) | x87 stack registers, *physical* slot order (st0 = top) |
| `fctrl`,`fstat`,`ftag` | hex string (16-bit) | control / status / tag words |
| `fop` | hex string (16-bit) | last x87 opcode |
| `fioff`,`fooff` | hex string (32-bit) | FPU instruction / data pointers (offset) |
| `fiseg`,`foseg` | hex string (16-bit) | FPU instruction / data pointers (selector) |

### 2.3 Cycle-mode fields (`mode:"cycle"`)
| key | type | meaning |
|---|---|---|
| `cyc` | int | **cumulative** core-clock count at this instruction's retire |
| `pipe` | string | `"U"`, `"V"`, or `"-"` (not issued to a pipe / microcoded) |
| `paired` | bool | true if this instruction issued paired with its sibling |
| `stall` | int *(optional)* | stall cycles attributed to this instruction (AGI, miss, mispredict…) |

(`cyc` is cumulative so the comparator can derive per-instruction deltas and a
total without summing; per-instruction cost = `cyc[n] - cyc[n-1]`.)

---

## 3. Comparator semantics (`verif/diff/compare.py`)

### Functional mode (Producer A vs Producer C)
Align records by `n`. For each pair compare, in order, the **defined** fields:
`pc`, then GPRs, `eflags`, segment selectors, and (if both headers say `x87`)
the x87 fields. Report the **first divergence** as
`{n, pc, field, expected (qemu), got (rtl)}` and stop (or `--all` to list all).

**EFLAGS masking.** Compare EFLAGS under an architectural mask. Default mask
keeps the standard arithmetic/status/control/system flags and ignores reserved
bits; `--eflags-mask 0x...` overrides. After instructions that leave some flags
**architecturally undefined** (e.g. `MUL`/`IMUL`/`DIV` on certain flags, shifts
by a masked count), those flags are excluded from the compare for that record.
The undefined-flag table lives in `tracefmt.py` and is documented there per
instruction. For M0 the smoke corpus avoids undefined-flag cases.

### Cycle mode (Producer B vs Producer C)
Align by `n`; sanity-check `pc` matches. Compare cumulative `cyc` and total cycle
count within a **tolerance band** (`--tol-pct`, default 0 for exact microbench
gates, looser for whole benchmarks). Report per-instruction deltas where they
diverge beyond tolerance, plus aggregate CPI / pairing% / pipe mix. Cycle
equality is approximate by construction — the cycle oracle is itself an estimate
(see harness README "What it does NOT model").

### Exit status
`0` = traces equivalent under the selected mode/tolerance; `1` = divergence
found; `2` = malformed input / length mismatch the modes don't allow.

---

## 4. M0 expectation (the skeleton gate)

At M0 the RTL is a **NOP stub** that boots reset and retires a fixed canned
sequence, so its functional trace will **not** match QEMU. The M0 gate is
**infrastructure**, not correctness: every producer emits a well-formed
`.vtrace`, and the comparator runs end-to-end and reports a *coherent* first
divergence (correct `n`/`field`, sensible expected-vs-got). Real functional
agreement begins at M1.
