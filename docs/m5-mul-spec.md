# M5 MUL/IMUL staged-timing design spec

Status: **IMPLEMENTED + GATED (2026-06-05).** REVIEW_Jun5.md Limit #5,
Actions 3/5/7/8 for the integer multiply family.

MUL/IMUL were computed by native `*` in one execute clock (charging ~7 cyc via
the slow FSM) where the P5 (p5model) charges **occ=10** (NP, U-pipe, all widths).
Closed exactly like the divider occupancy: the native `*` still produces the
bit-exact result; the modeled occupancy is charged as a DEFERRED penalty
(`pending_mem_pen <= occ - 7 = 3`) in `rtl/core/core_exec.svh` for all three forms
— 1-operand MUL (K_MULDIV q_md 4), 1-operand IMUL (q_md 5), and 2/3-operand IMUL
(K_IMUL2). Holds the U pipe so a dependent consumer stalls the latency. NEW gated
bands `mb_mul` + `mb_imul2` (CPI-elevation AND abs-cyc within 10% of the p5model
golden, in `verif/m5_metrics.py`, wired into `verify.sh` + `run-m5.sh`) both PASS
(+0.31% / +0.15%). Functional behaviour byte-unchanged (timing-only). The
remaining multiply work is purely structural (a real staged Booth/array
multiplier instead of native `*` — no architectural or timing observable).

Owner doc; the occupancy edits are in `rtl/core/core_exec.svh` + the bands in
`verif/m5_metrics.py` + `verif/tests/mb_mul`,`mb_imul2`.

---

## 1. Current implementation (verified against code)

`rtl/core/core_exec.svh`:
- **One-operand MUL/IMUL** — `K_MULDIV` arm, sub-ops `q_md==3'd4` (MUL,
  unsigned) and `3'd5` (IMUL one-operand, signed), ~lines 218–246.
- **Two/three-operand IMUL** — `K_IMUL2` arm, ~lines 287–307 (`IMUL r,r/m`,
  `IMUL r,r/m,imm`).

All forms compute the product with **native Verilog `*`** in a single `S_EXEC`
execute clock:
- MUL: `{8'd0,EAX[7:0]}*{8'd0,srcv[7:0]}` (8), `{16'd0,...}*{16'd0,...}` (16),
  `{32'd0,EAX}*{32'd0,srcv}` (32) → `EAX`/`EDX:EAX` written; CF=OF=ovf.
- IMUL one-op: `$signed(...)` operands, same one-shot structure; EDX:EAX written.
- IMUL two/three-op: `$signed(s1)*$signed(s2)` → single-register destination;
  CF=OF set from whether the result fits the destination width.
- EFLAGS handling matches QEMU `compute_all_mul` / `CC_OP_MUL`
  (ZF/SF/PF from low result, AF=0, CF=OF=overflow) — `core_exec.svh:227-231`,
  `301-305`. This is functionally correct and diff-clean today.

Cycle behavior: like DIV, MUL/IMUL route to the slow FSM (NOT in the fast-path
whitelist, `rtl/core/core_fastpath.svh`) and retire in ONE `S_EXEC` clock,
charging 1 cycle. The p5model charges **occ = 10** (NP). So the RTL
**undercounts multiply occupancy**, and — as with DIV — no current band catches
it because no band uses MUL (see §6).

The cycle-model machinery is the same `stall_cnt` / FP-occupancy template
described in `docs/m5-div-spec.md` §1; this spec reuses it.

---

## 2. Target Pentium timing (documented)

From p5model.c:257-258
(`ventium-refs/07-p5-emulation-harness/plugin/p5model.c`):

```c
case X86_INS_MUL: case X86_INS_IMUL:
    ii->mix=MIX_MUL; ii->pclass=NP; ii->occ=10; ii->lat=10; break;
```

- **Occupancy ≈ 10 cycles** (the documented Pentium integer multiply latency is
  ~10–11; p5model uses 10), **`lat == occ`**.
- **Class NP** — multiply is **non-pairable** and executes alone in the U pipe
  (`docs/ap500-pairing-table.md:75` lists `MUL, IMUL, DIV, IDIV` as NP). It
  serializes the pipe for its occupancy window.
- All MUL/IMUL widths and operand forms use the same ~10-cycle model in the
  oracle (the spec does not separate 8/16/32 for multiply, unlike divide).

---

## 3. Proposed design — staged multiply timing

### 3.1 Keep native `*` as the arithmetic primitive (Action 5/8)

Action 5 explicitly permits: "Native `*` can remain as an internal arithmetic
primitive if needed, but the visible instruction should occupy the pipe through
an explicit multi-cycle sequence with correct U-pipe-only serialization and
dependency behavior." So the *product value* stays computed by the existing
native-`*` helper (bit-exact vs QEMU, already proven), and only the **timing
path** changes.

### 3.2 Staged occupancy + serialization (Action 3)

Convert the one-shot `S_EXEC` multiply arm into an explicit multi-cycle
sequence — the integer twin of the FP occupancy mechanism
(`core_fastpath.svh:108-117`, `fp_occ`/`fp_occ_pending`/`fp_issue_cyc`):

```
S_MUL: read operands (EAX + src, or r/m + r/imm for IMUL2)   (operand read)
       -> compute product via native `*` helper              (internal step)
       -> burn mul_cnt = (10 - 1) clocks                      (occupancy)
       -> writeback (EDX:EAX for 1-op; single reg for IMUL2)  (writeback)
       -> set CF/OF/... EFLAGS exactly as today               (flags)
       -> retire                                              (retire)
```

- **U-pipe-only serialization:** MUL/IMUL are NP. The sequencer holds the U pipe
  for the full ~10-clock window so the next instruction cannot issue until
  multiply retires (FP `pipe_free_at = issue + occ` analogue). Anchor the
  following instruction's AGI/dependency check at the retire clock (mirror
  `fp_issue_cyc`/`fp_occ_pending`) so EAX/EDX writes do not create a phantom AGI
  on the issue clock.
- **Dependency behavior:** mark the destination register(s) ready at
  `issue + lat (=10)` on a dependency scoreboard so a dependent consumer stalls
  the multiply latency — same as the FP latency scoreboard
  (`fp_ready_cyc`). For 1-operand MUL/IMUL both EAX and EDX become ready at
  `issue + 10`; for IMUL2 only the single destination register.

### 3.3 Architectural equivalence (Action 7)

Retain the exact product + EFLAGS computation (`compute_all_mul`/`CC_OP_MUL`
semantics) so `make verify` stays diff-clean vs QEMU; the only delta is timing,
so there is no new functional behavior to test (unlike DIV's `#DE`).

---

## 4. New microbenchmark (Action 7)

Place under `verif/tests/` (`.s` + `.elf`), mirroring `mb_depadd`/`mb_fpocc`:

| Microbench  | Kernel content                                  | Tests |
|-------------|-------------------------------------------------|-------|
| `mb_mul`    | tight loop of independent `MUL/IMUL r/m32`      | occupancy ≈10/op; non-pairing; U-pipe hold |
| `mb_muldep` | MUL then a dependent op reading EAX/EDX          | result-latency stall (lat=10 coupling) |

`mb_mul` proves occupancy + non-pairing; `mb_muldep` proves the result-latency
coupling (a following `add ebx,eax` cannot issue until `issue + 10`). Add an
`IMUL2`-form variant (`mb_imul2`) if the two-operand timing must be separately
gated (it shares occ=10, so a single `mb_mul` band may suffice initially).

---

## 5. p5model band the microbench must hit (Action 10)

As with DIV (`docs/m5-div-spec.md` §5), `verif/m5_metrics.py` has **no MUL
band** — an unknown kernel returns `INFO` (`m5_metrics.py:219`) with no
PASS/FAIL. A NEW band is required:

- **`mul` band (NEW):** abs-cyc within `DEFAULT_ABS_TOL_PCT` (10%) of the
  p5model golden, AND a per-op-occupancy check `total_cyc / n_mul ≈ 10` within
  band. Pattern this on the `dmiss`/`imiss` two-part band (CPI elevation +
  abs-cyc tracking).
- **`muldep` band (NEW):** dependent-multiply CPI ≳ independent `mul` CPI
  (latency coupling), the multiply analogue of `faddchain` vs `fpindep`.

`m5_metrics.compute()` must gain `short == "mul"` and `short == "muldep"`
branches with documented constants.

---

## 6. RISK

- **No existing M4/M5 band uses MUL** (all current bands measure
  ADD/MOV/LEA/branch/FP/cache kernels). Landing staged multiply changes NO
  current band, and gets NO gate until the new `mb_mul`/`mb_muldep` kernels AND
  the new `m5_metrics` bands land alongside the RTL.
- **occ=10 is the p5model oracle value, not silicon-measured** — label it
  "cycle-modeled," per Action 9. (Public sources quote ~10–11 cycles for the P5
  integer multiplier; the oracle pins 10.)
- **Calibration drift:** changing multiply from 1 clock to ~10 perturbs any
  aggregate cycle figure that includes a multiply; re-baseline any touched
  golden trace.
- **No functional change** (the product/flags math is unchanged), so functional
  regression risk is LOW — the risk is confined to timing calibration and to the
  new bands.
