# M5 DIV/IDIV iterative-divider design spec (DEFERRED)

Status: **SPEC ONLY — not implemented in this change set.** This captures
REVIEW_Jun5.md Limit #5, Actions 3/4/7/8 for the integer divide family. It
perturbs the calibrated M4/M5 cycle bands and needs NEW microbenchmarks, so it
is tracked as incremental work, not landed now.

Owner doc; touches no `rtl/` and no Makefile.

---

## 1. Current implementation (verified against code)

`rtl/core/core_exec.svh`, `K_MULDIV` arm (~line 247, sub-ops `q_md==3'd6` DIV
and `default` IDIV /7), inside the slow functional FSM's `S_EXEC` state:

- DIV and IDIV are computed with **native Verilog `/` and `%`** in a single
  `S_EXEC` execute clock:
  - r/m8:  `gpr[EAX][15:0] / srcv[7:0]` (16/8 → AL=quot, AH=rem).
  - r/m16: `{EDX[15:0],EAX[15:0]} / srcv[15:0]` (32/16 → AX=quot, DX=rem).
  - r/m32: `{EDX,EAX} / srcv` (64/32 → EAX=quot, EDX=rem).
  - IDIV uses `$signed(...)` operands, same one-shot structure.
- `EDX:EAX` coupling is present *functionally* (the dividend is the EDX:EAX
  concatenation and the remainder writes EDX) but it is not exposed as pipe
  occupancy or serialization — the whole op retires in one execute clock.
- **No `#DE`.** There is NO divide-by-zero or quotient-overflow check. Grep of
  `rtl/core/core.sv` / `core_exec.svh` shows no `d_int_vec=8'd0` raised from the
  divide path; a zero divisor evaluates native `/`/`%` (X-prone / undefined)
  rather than vectoring to exception 0. **Closing this gap is part of this
  work.**
- Pairing: DIV/IDIV are **NP** (never pairable) per
  `docs/ap500-pairing-table.md` line 75 and the p5model
  (`ventium-refs/07-p5-emulation-harness/plugin/p5model.c:259-266`). They are
  not in the fast-path whitelist (`rtl/core/core_fastpath.svh`), so they already
  fall to the slow FSM — correct for pairing, but they retire in one clock, so
  the *occupancy* is wrong (1 clock instead of 17–46).

### How the cycle model counts execute cycles (verified)

The S_PIPE fast path advances `core_cyc` one clock per FSM clock
(`core.sv:3028 core_cyc <= core_cyc + 1`). Multi-cycle occupancy is materialised
by `stall_cnt` (`core.sv:756 logic [6:0] stall_cnt`): an op records how many
extra clocks to burn before it retires, and `S_PIPE` counts it down
(`core_fastpath.svh:37` `if (stall_cnt!=0) stall_cnt<=stall_cnt-1`). The
**existing FP template** is the model to copy: `fp_occ` (decode-supplied
occupancy), `fp_occ_pending`, `fp_issue_cyc`, and the
`stall_cnt <= fp_occ - 2` burn (`core_fastpath.svh:108-117`). A DIV/IDIV
occupancy model is the integer analogue of that FP-occupancy mechanism.

DIV/IDIV currently never enter S_PIPE occupancy logic — they take the slow FSM
and retire in one `S_EXEC` clock, charging 1 cycle. The p5model oracle, by
contrast, charges 17–46. **The current RTL therefore UNDERCOUNTS divide
occupancy; no existing band catches this because no band uses DIV (see §6).**

---

## 2. Target Pentium occupancy (documented)

From p5model.c:259-266 (its own source is Agner Fog P5 tables +
`ventium-refs/03-optimization-timing`), the modeled non-pipelined occupancy
(`occ`) and result latency (`lat`) — `occ == lat`, NP:

| Op   | r/m8 | r/m16 | r/m32 |
|------|-----:|------:|------:|
| DIV  | 17   | 25    | 41    |
| IDIV | 22   | 30    | 46    |

These are the documented Pentium divide latencies (DIV ~17/25/41; IDIV a few
cycles more for the sign handling). The sequencer must hold the U pipe for
exactly `occ` clocks per operand size, and IDIV must add its extra cycles over
DIV at the same width.

---

## 3. Proposed design — iterative-divide sequencer

### 3.1 Architectural result: keep the native helper (Action 8)

Per Action 8 ("separate architectural implementation from timing"), the
*quotient/remainder values* may still be computed by the existing native
`/`/`%` helper logic — bit-exact vs QEMU is already proven by the functional
diff. What changes is the **timing-visible path**: the instruction must occupy
the pipe through an explicit multi-cycle sequence and retire only after the
modeled occupancy completes.

### 3.2 Occupancy + serialization

Add a `K_MULDIV`-divide occupancy field to the fast-path decode (the integer
twin of `fp_occ`), OR — since DIV/IDIV already route to the slow FSM — model
the occupancy in the slow path by having the `S_EXEC` divide arm transition
through a divide-sequencer state that burns `occ-1` clocks (a `div_cnt`
counter) before retiring, instead of retiring on the first execute clock.
Recommended: a small `S_DIV` micro-sequencer state with explicit micro-ops, per
Action 3 ("read operands → internal step(s) → writeback → retire"):

```
S_DIV: read EDX:EAX + divisor          (operand-read micro-op)
       -> compute quot/rem via native helper (internal step)
       -> burn div_cnt = occ(width, signed) clocks   (occupancy)
       -> writeback EAX=quot, EDX=rem                 (writeback micro-op)
       -> retire                                       (retire micro-op)
```

- **U-pipe serialization:** DIV/IDIV are NP. The sequencer must hold the U pipe
  for the whole `occ` window so the next instruction cannot issue until divide
  retires — exactly the FP `pipe_free_at = issue + occ` rule. Mirror the FP
  occupancy bookkeeping (`fp_issue_cyc`/`fp_occ_pending`) with a divide twin so
  AGI/pairing of the *following* instruction is anchored at the retire clock,
  not the issue clock (avoids a phantom AGI on EAX/EDX).
- **EDX:EAX coupling:** make the dividend read (EDX:EAX) and the dual writeback
  (EAX quot, EDX rem) explicit micro-ops so the dependency scoreboard marks both
  EAX and EDX written at `issue + occ` (a dependent consumer of EDX must stall
  the full latency, like the FP latency scoreboard).

### 3.3 `#DE` — divide error (Action 4)

Add the missing exception 0 (`#DE`) BEFORE the occupancy burn:

- **Divide-by-zero:** divisor == 0 → `#DE` (vector 0). No quotient/remainder
  writeback; no EFLAGS change (architectural: undefined, leave unchanged).
- **Quotient overflow:** quotient does not fit the destination width →
  `#DE`. Precisely:
  - DIV: quotient `> 0xFF` (8), `> 0xFFFF` (16), `> 0xFFFF_FFFF` (32).
  - IDIV: quotient outside signed `[-2^(n-1), 2^(n-1)-1]` for n = 8/16/32, with
    the standard `0x80…/-2^(n-1)` corner.
- Vector via the same int-delivery path used by other faults (`d_int`,
  `d_int_vec=8'd0`, `core_int_deliver.svh`). In user/co-sim mode the trap must
  match QEMU's `#DE` (the diff harness sees the fault delivery). Document the
  timing: the documented occupancy still applies up to the fault detection
  point; model #DE detection as occurring at the operand-read micro-op (charge
  the detection clocks, then deliver — exact #DE timing is not pinned by the P5
  docs, so label it cycle-modeled, Action 9).

### 3.4 Architectural equivalence (Action 7)

The functional result (quot/rem placement, flag-undefined behavior, and the new
`#DE`) must stay diff-clean vs QEMU under `make verify`. Because the native
helper is retained, the only functional delta is the added `#DE` — which must be
matched by a new functional test (see §5, `tx_de_*`).

---

## 4. New microbenchmarks (Action 7)

Place under `verif/tests/`, with `.s` + `.elf`, mirroring the existing
`mb_depadd`/`mb_fpocc` structure. Each must hit a NEW p5model band (see §5).

| Microbench      | Kernel content                                         | Tests |
|-----------------|--------------------------------------------------------|-------|
| `mb_div32`      | tight loop of independent `DIV r/m32` (reload EDX:EAX) | occupancy 41/op; non-pairing; U-pipe hold |
| `mb_div16`      | loop of `DIV r/m16`                                    | occupancy 25/op |
| `mb_div8`       | loop of `DIV r/m8`                                     | occupancy 17/op |
| `mb_idiv32`     | loop of `IDIV r/m32`                                   | occupancy 46/op (IDIV > DIV at same width) |
| `mb_divdep`     | DIV then dependent op reading EAX/EDX                  | result-latency stall (EDX:EAX coupling) |
| `tx_de_div0`    | DIV by zero (functional, NOT a band)                   | `#DE` delivered, diff-clean vs QEMU |
| `tx_de_divovf`  | DIV quotient overflow (functional)                     | `#DE` delivered |

`mb_divdep` proves the EDX:EAX latency coupling (a following `add ebx,eax`
stalls until `issue + occ`); `mb_div32` proves the occupancy/non-pairing.

---

## 5. p5model bands each microbench must hit (Action 10)

`verif/m5_metrics.py` currently defines bands ONLY for
`depadd/indepadd/agi/brloop/brrandom/agiloop` (delegated to `m4_metrics`) and
`faddchain/fpindep/dmiss/imiss`. There is **no DIV/MUL band** — an unknown
kernel falls to the `INFO` branch (`m5_metrics.py:219`, "no M5 band defined")
and produces NO PASS/FAIL gate. So NEW bands are required:

- **`div32`/`div16`/`div8`/`idiv32` band (NEW):** abs-cyc within the M5
  tolerance (`DEFAULT_ABS_TOL_PCT = 10%`) of the p5model golden, AND a
  per-op-occupancy check: `total_cyc / n_div ≈ occ(width)` within band (41/25/17
  for DIV, 46 for IDIV32). This is the divide analogue of the `dmiss`/`imiss`
  two-part band (CPI elevation + abs-cyc tracking).
- **`divdep` band (NEW):** the dependent-divide CPI must exceed the independent
  one by the latency coupling, analogous to `faddchain` vs `fpindep`. Concretely
  `divdep` CPI ≳ `div32` CPI (a dependent EDX:EAX consumer cannot hide the
  divide latency).

`m5_metrics.compute()` must gain a `short in ("div32","div16","div8","idiv32")`
branch and a `divdep` branch, with the band constants documented there (mirror
the `MISS_CPI_MIN` / abs-cyc pattern).

---

## 6. RISK

- **No existing M4/M5 band uses DIV.** All current bands measure
  ADD/MOV/LEA/branch/FP/cache kernels (§5). Therefore landing the iterative
  divider changes NO current band — but it also gets NO gate coverage until the
  new `mb_div*`/`mb_idiv*` kernels AND the new `m5_metrics` bands above are
  added. The microbenchmarks and bands MUST land together with the RTL, or the
  occupancy change is unverified.
- **p5model occupancy is the oracle, not silicon.** The 17/25/41 (DIV) and
  22/30/46 (IDIV) numbers come from the p5model/Agner tables; they are
  cycle-modeled, not transistor-measured. Label the result "cycle-modeled," per
  Action 9.
- **`#DE` is a new architectural behavior.** It must be added under the
  functional diff (it changes QEMU-observable behavior for div-by-zero/overflow
  inputs) and gated by the `tx_de_*` tests — a behavior change, not just a timing
  change, so it carries functional regression risk and needs `make verify` to
  stay clean on all 57 existing programs.
- **Calibration drift:** changing divide from 1 clock to 17–46 clocks perturbs
  any aggregate cycle figure that happens to include a divide; re-baseline the
  golden traces for any kernel touched.
