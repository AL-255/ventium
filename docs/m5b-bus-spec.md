# M5B — pin-level 64-bit external Bus Interface Unit (BIU) spec

M5B (PLAN §6/§9) is the **pin-level external bus interface** of the Pentium
(P5/P54C): the FSM that turns internal memory requests into the external
ADS#/BRDY#/NA#/burst/locked/pipelined/snoop protocol on the 64-bit data bus.

## Why this is deferred / no-oracle (the M2S pattern)

The cycle oracle (`build/p5trace.so`, the p5model U/V estimate) models an L1
cache miss as a **fixed cycle penalty** (`imiss/dmiss`), **not** as bus pins, and
QEMU has no pin-level bus trace. So there is **no differential oracle** for the
BIU. It is therefore verified **structurally**:

1. **SVA concurrent protocol invariants** — the bus-protocol rules from the
   datasheet (Table 2, §3), encoded as assertions that hold on every clock.
2. **A directed self-consistency testbench** — one stimulus scenario per bus-cycle
   type (single R/W, burst line fill, locked RMW, pipelined, inquire/snoop, BOFF#
   backoff, HOLD/HLDA, reset), with a behavioral "system" model answering the bus.

Real silicon-exact validation would need logic-analyzer / FPGA bus traces we do
not have (REF.md §4, layer 2). We do not claim silicon-exact timing here; we claim
the FSM **obeys the documented bus protocol** and is **self-consistent**.

## Isolation note

This block is built **fully standalone** under `verif/bus/`. The module is named
`biu_p5`, lives in `verif/bus/biu_p5.sv`, declares its **own localparams** (it
does **not** import `ventium_pkg`), and never reads `rtl/`. Integration into
`rtl/bus/` and wiring into the core is a **later orchestrator step** after the M5
cycle-timing track lands — out of scope for this workflow.

Authoritative source: Pentium datasheet **241997-010**, Table 2 (Quick Pin
Reference, PDF p.13–21) and §3 Bus Functional Description.

---

## 1. External bus pin list (the `biu_p5` ports)

Active-low signals carry the datasheet `#` suffix in their description; in RTL the
`#`-suffixed signals are named `_n` and are **asserted = logic 0**. The module is
clocked by `clk` (rising edge) with synchronous active-high `reset`.

### Clock / reset

| Port | Dir | Active | Function |
|------|-----|--------|----------|
| `clk`       | in  | rising | Bus clock (CLK). All synchronous signals referenced to its rising edge. |
| `reset`     | in  | high   | RESET. Synchronous; forces FSM to idle, bus inactive (outputs negated / floated per Table 4). |

### Address / cycle definition (driven with ADS#)

| Port | Dir | Active | Function |
|------|-----|--------|----------|
| `adsn`      | out | low (0) | **ADS#** — address status. Asserted **exactly one clock** to start a new bus cycle. |
| `a`         | out | —       | **A31–A3** address lines (29 bits). Driven valid with ADS#. Floated during AHOLD/HOLD/BOFF#. |
| `be_n`      | out | low (0) | **BE7#–BE0#** byte enables (8 bits). Driven with the address. |
| `mion`      | out | —       | **M/IO#** — memory(1)/IO(0). Driven valid with ADS#. |
| `dcn`       | out | —       | **D/C#** — data(1)/code(0). Driven valid with ADS#. |
| `wrn`       | out | —       | **W/R#** — write(1)/read(0). Driven valid with ADS#. |
| `cachen`    | out | low (0) | **CACHE#** — cacheable/burst cycle indicator. Driven with ADS#; determines cycle length (asserted ⇒ burst-capable). |
| `scycn`     | out | low (0) | **SCYC** — split cycle (locked, misaligned, >2 locked transfers). |
| `lockn`     | out | low (0) | **LOCK#** — asserted first clock of first locked cycle, negated after BRDY# of last locked cycle. |

### Data / cycle completion

| Port | Dir | Active | Function |
|------|-----|--------|----------|
| `d_out`     | out | —       | **D63–D0** write data (64 bits). Driven in T2/T12/T2P of a write. |
| `d_in`      | in  | —       | **D63–D0** read data (64 bits). Sampled when BRDY# returned on a read. |
| `d_oe`      | out | high    | Data-bus output enable (1 ⇒ BIU drives `d_out`). Models the bidirectional D63–D0 pin float. |
| `brdyn`     | in  | low (0) | **BRDY#** — burst ready. Each beat completes on BRDY#. Sampled in T2/T12/T2P. |
| `nan`       | in  | low (0) | **NA#** — next address. When asserted, system is ready for a new cycle before the current finishes ⇒ pipeline (issue next ADS# 2 clocks later, ≤2 outstanding). |
| `kenn`      | in  | low (0) | **KEN#** — cache enable. Qualified at first BRDY#/NA#: CACHE# asserted **and** KEN# active ⇒ cycle becomes a 4-beat burst line fill. |

### Arbitration

| Port | Dir | Active | Function |
|------|-----|--------|----------|
| `hold`      | in  | high    | **HOLD** — bus hold request. Float outputs, assert HLDA. Not recognized during LOCK#; recognized during reset. |
| `hlda`      | out | high    | **HLDA** — hold acknowledge. Asserted when bus relinquished. |
| `boffn`     | in  | low (0) | **BOFF#** — backoff. Abort outstanding cycle(s), float pins next clock; restart aborted cycle(s) in entirety after negation. |
| `breq`      | out | high    | **BREQ** — bus request (BIU has an internal request pending). |

### Inquire / snoop

| Port | Dir | Active | Function |
|------|-----|--------|----------|
| `ahold`     | in  | high    | **AHOLD** — address hold. BIU stops driving A31–A3/AP next clock; rest of bus stays active so outstanding data can return. |
| `eadsn`     | in  | low (0) | **EADS#** — valid external (snoop) address on A31–A5. Latched with INV for an inquire cycle. |
| `inv`       | in  | high    | **INV** — invalidate; final cache-line state after an inquire hit (1 ⇒ I, 0 ⇒ S). Sampled with EADS#. |
| `a_in`      | in  | —       | **A31–A5** inquire address driven by the system during AHOLD (snoop address input). |
| `hitn`      | out | low (0) | **HIT#** — inquire result; driven 2 clocks after EADS# (asserted = hit, negated = miss). Retained between cycles. |
| `hitmn`     | out | low (0) | **HITM#** — hit to a **modified** line; asserted after an inquire hit-modified, held until the writeback completes. |
| `a_oe`      | out | high    | Address-bus output enable (1 ⇒ BIU drives `a`). Models A31–A3/AP float under AHOLD/HOLD/BOFF#. |

### Core-side request interface (defined by us; see §4)

| Port | Dir | Function |
|------|-----|----------|
| `req`       | in  | Core asserts to request a bus cycle. |
| `req_we`    | in  | 1 = write, 0 = read. |
| `req_cache` | in  | 1 = cacheable (drives CACHE#); a cacheable read with KEN# active becomes a burst line fill. |
| `req_lock`  | in  | 1 = locked cycle (drives LOCK# across the locked group). |
| `req_split` | in  | 1 = misaligned / >2-cycle locked group ⇒ drives SCYC (only meaningful with `req_lock`). |
| `req_mio`   | in  | M/IO# value for the cycle. |
| `req_dc`    | in  | D/C# value for the cycle. |
| `req_addr`  | in  | A31–A3 address (29 bits). |
| `req_be`    | in  | BE7–BE0 byte enables (8 bits, active-high to core, inverted to `be_n`). |
| `req_wdata` | in  | 64-bit write data (single) or first beat (burst writeback). |
| `req_wb`    | in  | 1 = **this write IS the snoop-hit writeback**; its terminating BRDY# releases HITM#. A normal store sets 0 and does not release HITM#. |
| `req_ack`   | out | BIU pulses 1 clock when it has accepted the request into the FSM (ADS# issued). |
| `rsp_valid` | out | BIU pulses 1 clock per returned beat (read data valid / write beat done). |
| `rsp_data`  | out | 64-bit read data for the current beat (valid with `rsp_valid` on reads). |
| `rsp_last`  | out | 1 on the final beat of the cycle (beat 1 of 1 for single, beat 4 of 4 for burst). |
| `wb_req`    | out | 1 while a snoop hit-modified writeback is pending (raised at HITM#, cleared when the `req_wb` write completes). |

Observability-only outputs (not functional; used by the SVA testbench, leave
unconnected at integration): `dbg_state`, `dbg_is_burst`, `dbg_outstanding`,
`dbg_pipe_burst`, `dbg_inv_state` (captured INV: 1=I,0=S), `dbg_snoop_state`.

---

## 2. Bus-cycle state machine

States (one-hot internally; documented names):

```
RESET ──> IDLE
IDLE  ── core req & bus free ───────────────> T1      (drive ADS# + addr/ctrl, 1 clock)
T1    ── unconditional next clock ──────────> T2      (ADS# negated; sample BRDY#/NA#/KEN#)
T2    ── BRDY# & last beat & !NA# ──────────> IDLE
T2    ── BRDY# & !last beat ────────────────> T2      (next burst beat; addr A4..A3 advances)
T2    ── NA# (pending req) & !done ─────────> T12     (pipeline: issue next ADS# while current data outstanding)
T12   ── (ADS# of pipelined cycle, 1 clk) ──> T2P
T2P   ── BRDY# completes 1st cycle ─────────> T2      (2nd cycle becomes the current cycle)
any   ── BOFF# ─────────────────────────────> BOFF    (float, abort)
BOFF  ── !BOFF# ────────────────────────────> T1      (restart aborted cycle from ADS#)
IDLE/done ── HOLD & !LOCK# ─────────────────> HOLD_ST (float outputs, assert HLDA)
HOLD_ST ── !HOLD ───────────────────────────> IDLE
```

Orthogonal snoop tracking runs **in parallel** with the data FSM (AHOLD floats only
the address bus; data cycles in flight keep completing):

```
SNOOP_IDLE ── EADS# (during AHOLD) ─> SNOOP_S1 ─> SNOOP_S2 (drive HIT#/HITM# here, 2 clks after EADS#)
SNOOP_S2   ── hit & line modified ──> writeback pending (HITM# held until WB BRDY# done)
```

### Cycle types implemented

1. **Single read** — IDLE→T1→T2; 1 BRDY# terminates; `rsp_valid`+`rsp_last` with read data. CACHE# negated.
2. **Single write** — IDLE→T1→T2; drive `d_out`/`d_oe`; 1 BRDY# terminates.
3. **Burst line fill (4 beats)** — cacheable read (`req_cache`) with KEN# active at first BRDY#/NA# ⇒ CACHE# asserted, 4 × 64-bit beats, 4 BRDY#. `rsp_last` only on beat 4. **Burst order follows Developer's Manual Vol.1 Table 6-12** (the two-bank-optimized sequence), computed as `A[4:3]_beat = base ^ beat_idx` (which reproduces Table 6-12 exactly for every start offset: base 0→0,1,2,3; base 1→1,0,3,2; base 2→2,3,0,1; base 3→3,2,1,0). The **address and byte-enables are driven on the bus for the first transfer only and are NOT re-driven** for the remaining beats (the model drops `a_oe` after T1 of a burst); subsequent beat addresses are the system/external-hardware's responsibility (`a` is held internally only to *model* the line, never re-asserted on the pins).
4. **Locked cycle (RMW pair)** — `req_lock` ⇒ LOCK# asserted in first clock of first locked cycle, **held across both** cycles (read then write), negated after BRDY# of the second. HOLD not granted while LOCK# asserted (AHOLD/BOFF# still allowed). **SCYC** is asserted **only** for a misaligned / >2-cycle locked group (`req_split`); a normal aligned 2-cycle RMW pair leaves SCYC **negated** (datasheet: SCYC is defined for locked cycles only and indicates >2 cycles locked together).
5. **Pipelined cycle** — system asserts NA# in T2; if a second request is pending, BIU drives the second ADS# (T12) while the first cycle's data is still outstanding (T2P), ≤2 outstanding cycles.
6. **Inquire / snoop** — system asserts AHOLD (BIU floats `a`/`a_oe`), then EADS# with INV; BIU drives HIT# 2 clocks later (and HITM# if the line was modified). An inquire hit to a **Modified** line **always** asserts HITM# and requests a writeback **regardless of INV**; INV selects only the *final* cache-line state after the writeback (1 ⇒ Invalid, 0 ⇒ Shared), exposed on `dbg_inv_state`. HITM# is held until the **actual writeback** of the snooped line completes — it is released only by a write cycle tagged `req_wb` (not by any unrelated store). EADS# is honored whenever the system owns the address bus (AHOLD, HLDA, or BOFF#).
7. **BOFF# backoff** — assertion floats all pins next clock and aborts **all** outstanding cycles; on negation **every aborted cycle is restarted in its entirety** (datasheet wording: "restarts the aborted bus cycle(s)"). If two cycles were outstanding (a pipelined pair in T2P), the older one restarts first from a fresh ADS#; the second is re-queued and re-launched (also from a fresh ADS#) after the first completes — neither is dropped, and a burst's full beat-count/position is preserved across the abort.
8. **HOLD / HLDA** — HOLD (when not in a locked cycle) floats outputs and asserts HLDA; bus returns on HOLD negation. HOLD is also **recognized during RESET** (HLDA may assert while RESET is held).
9. **Reset** — synchronous reset → IDLE, ADS#/LOCK#/HIT#/HITM# negated, `a_oe`/`d_oe` low (bus inactive), HLDA low (unless HOLD is asserted during reset, in which case HLDA asserts).

---

## 3. SVA protocol invariants (the checks)

These are **SystemVerilog concurrent assertions**, `@(posedge clk) disable iff
(reset)` unless noted, in `verif/bus/tb_biu_p5.sv` — **19 `assert property`
statements** in total. Each is non-vacuous: it has been validated by **mutation
testing** (re-injecting the corresponding bug and confirming the assertion or a
paired directed check fires). The directed self-consistency scenarios (one per
bus-cycle type plus a corner per fixed defect) drive the stimulus that exercises
them; **76 directed `chk()` checks** must also pass.

| # | Invariant | Form |
|---|-----------|------|
| **P1**  | ADS# is a one-clock pulse | `$fell(adsn) |=> $rose(adsn)` |
| **P2**  | BRDY# beat count: 1 (single) / 4 (burst) at `rsp_last` | beat counter + burst latch; fires if a burst is truncated or mis-counted |
| **P3**  | No ADS# from an illegal state (only IDLE / T12 / BOFF) | `$fell(adsn) |-> $past(state)∈{IDLE,T12,BOFF}` |
| **P3b** | Pipelined ADS# (from T12) implies NA# was on the bus | tracks the **raw NA# pin** in T2 (not a mirror of the DUT branch — the previously-vacuous form is fixed) |
| **P4**  | ≤2 outstanding cycles | `dbg_outstanding <= 2` |
| **P5**  | LOCK# continuity: never glitches high mid-group | LOCK# may rise only when a locked write completed (`$rose(lockn) |-> $past(write+BRDY# in T2/T2P)`) |
| **P6**  | No HOLD grant during LOCK# | `!(hlda && !lockn)` |
| **P7**  | AHOLD floats the address bus | `$past(ahold) |-> !a_oe` |
| **P7b** | **No fresh ADS# while the address bus is floated** | `!adsn |-> a_oe` (catches issuing ADS# with a floated/invalid address under AHOLD) |
| **P8**  | A snoop launches only on a **qualified** EADS# | `SN_IDLE→SN_S1 |-> $past((ahold|hlda|!boffn) && !eadsn)` |
| **P9**  | HIT#/HITM# driven exactly **2 clocks after** EADS# | `$changed(hitn) |-> $past(snoop_state)==SN_S2` |
| **P10** | HITM# asserted implies a pending writeback | `!hitmn |-> wb_req` |
| **P10b**| HITM# released **only by the writeback** completing | `$rose(hitmn) |-> $past(write+BRDY# in T2/T2P)` |
| **P11** | BOFF# floats the bus next clock | `$fell(boffn) |=> (!a_oe && !d_oe && adsn)` |
| **P12** | BOFF# restart issues a fresh ADS# (cycle not dropped) | `BOFF→T1 |-> !adsn` |
| **P13** | Reset ⇒ inactive idle (HLDA may assert if HOLD held) | post-reset IDLE + all pins negated/floated |
| **P14** | `d_oe` only on writes | `d_oe |-> wrn==write` |
| **P14b**| **Write data not driven in T1** (driven from T2) | `state==T1 |-> !d_oe` |
| **P15** | BRDY# in IDLE with 0 outstanding ⇒ no spurious `rsp_valid` | guarded `rsp_valid` |

The mutation-tested defects (each re-injected and confirmed to FAIL the suite):
NA#/last-BRDY# race (double-`req_ack`), INV=1 modified-hit (HITM#/WB dropped),
BOFF# 2-cycle loss, pipeline-behind-burst truncation (P2), burst address
re-drive (P5-style directed), HITM# released by unrelated write (P10b/directed),
SCYC on a normal locked pair (directed), ADS# under AHOLD (P7b), write data in
T1 (P14b), LOCK# glitch mid-group (P5).

Results of these checks are echoed in the testbench `$display` summary
(`RESULT: ALL GREEN` ⇒ 0 failures) and the build returns exit 0.

---

## 4. Core-side request interface (for later integration)

The future core (intcore / cache controller) drives a **single-master req/ack +
beat-response** handshake; the BIU owns all external pin behavior. Contract:

1. Core raises `req` with `req_we/req_cache/req_lock/req_mio/req_dc/req_addr/
   req_be/req_wdata` held stable until `req_ack`.
2. BIU, when the bus is free (not HOLD/BOFF/locked-busy), issues ADS# and pulses
   `req_ack` for one clock (request accepted; core may prepare the next request —
   needed for pipelined and locked-pair cycles).
3. For each returned beat the BIU pulses `rsp_valid` (with `rsp_data` valid on
   reads); `rsp_last` marks the final beat (beat 1/1 single, beat 4/4 burst).
4. **Burst line fill:** core issues one cacheable read `req`; if KEN# qualifies, the
   BIU returns 4 beats (`rsp_valid` ×4, `rsp_last` on the 4th). Core reassembles the
   32-byte line.
5. **Locked pair:** core sets `req_lock` on **both** the read and the write request
   of an RMW; LOCK# is held by the BIU across the pair. Core must present the write
   request (after the read's `rsp_last`) while `req_lock` is still set. For a
   misaligned / >2-cycle locked group set `req_split` too (drives SCYC); a normal
   aligned pair leaves `req_split`=0 and SCYC negated.
6. **Pipelined:** if the core has a second `req` ready and the system asserts NA#,
   the BIU accepts it (a second `req_ack`) and overlaps it; ≤2 outstanding. The BIU
   will **not** pipeline a second cycle behind a burst, nor accept it on the same
   clock as the first cycle's terminating BRDY# (it then launches it as a fresh,
   non-pipelined cycle instead) — so the core always sees exactly one `req_ack`
   per accepted request.
7. **Snoop writeback:** on an inquire hit-modified the BIU raises `wb_req` so the
   cache can supply the modified line; the cache then issues that one write with
   `req_wb`=1. The BIU holds HITM# until **that** writeback's terminating BRDY#
   (unrelated stores in between do not release it). This is INV-independent: HITM#
   and the writeback always happen on a modified hit; INV only sets the post-WB
   line state (read it off `dbg_inv_state` if the cache needs it: 1=I, 0=S).

This interface deliberately hides T1/T2/T12/T2P, burst ordering, ADS#/BRDY#
sequencing, LOCK#, BOFF# restart and AHOLD/EADS# from the core — the core sees only
"request a cycle, get beats back."

---

## 5. INTEGRATION NOTE (for the orchestrator — do AFTER M5 lands)

This block is **complete and standalone in `verif/bus/` only**. It has **not**
been integrated into `rtl/` and this workflow does **not** touch `rtl/`,
`ventium_top.sv`, `intcore.sv`, the top `Makefile`, or `PROGRESS.md`. The steps
below are the orchestrator's later job.

### 5.1 What exists today (M0 stub)

At M0 the external bus is a single-beat BFM / stub at `rtl/bus/biu.sv`: a memory
request returns one 64-bit word with no ADS#/BRDY#/burst/snoop pin behavior (the
cache-miss latency is modeled in `p5model` as a *cycle penalty*, not as bus
pins). That stub path is what `ventium_top` wires the core memory port to today.

### 5.2 How `biu_p5` replaces the stub

1. **Move the module into the RTL tree:** copy `verif/bus/biu_p5.sv` to
   `rtl/bus/biu_p5.sv`. It is self-contained (its own localparams, no
   `ventium_pkg` import) so it drops in without package coupling. If the house
   style prefers package params, the localparams (`S_*`, `BURST_BEATS`,
   `SINGLE_BEATS`) can be migrated to `ventium_pkg` at that point — they are
   deliberately local now to keep this track isolated.
2. **Wire the core-side port (§1 "Core-side request interface"):** connect the
   cache/memory controller's request to `req / req_we / req_cache / req_lock /
   req_split / req_mio / req_dc / req_addr / req_be / req_wdata / req_wb`, and the
   responses to `req_ack / rsp_valid / rsp_data / rsp_last / wb_req`. The contract
   is the simple req/ack + beat-response handshake in §4 (req held stable until
   `req_ack`; one `rsp_valid` per beat; `rsp_last` on the final beat; ≤2
   outstanding). The `dbg_*` outputs are observability-only and left unconnected.
3. **Wire the external pins** (ADS#/A/BE#/M-IO#/D-C#/W-R#/CACHE#/SCYC/LOCK#,
   D63-0 with `d_oe`, BRDY#/NA#/KEN#, HOLD/HLDA/BOFF#/BREQ, AHOLD/EADS#/INV/A_in/
   HIT#/HITM#) out to `ventium_top`'s bus pins, **replacing the M0 single-beat BFM
   path**. The tristate/float modeling here is via the `*_oe` enables (`a_oe`,
   `d_oe`); at the top level these select between driving the pin and Hi-Z (or a
   pull as the board models).
4. **Cacheability hookup:** drive `req_cache` from the page/line cacheability
   (PCD/PWT/MTRR-equivalent) and qualify the resulting burst with the system's
   `KEN#`. The BIU upgrades a cacheable read to a 4-beat line fill internally.
5. **Snoop hookup:** route the inquire/snoop port to the L1/L2 tag pipe — `a_in`
   from the snoop address, `inv` from the snooping master's intent, and the
   cache must answer `wb_req` by issuing the modified line as a `req_wb`=1 write.
6. **Build/PROGRESS:** add `rtl/bus/biu_p5.sv` to the RTL filelist and a bus
   regression target; mark M5B in `PROGRESS.md`. (All of this is the orchestrator's
   later step — intentionally not done here.)

### 5.3 HONEST verification caveat

**This BIU is STRUCTURAL + SVA-verified ONLY — it is NOT differentially
verified.** There is no pin-level oracle: the cycle model (`p5model`) treats a
cache miss as a fixed cycle penalty and QEMU has no bus-pin trace, so nothing in
the existing differential harness can confirm the exact ADS#/BRDY#/NA#/burst/
snoop **pin waveforms**. What is proven here is that the FSM (a) **obeys the
documented bus protocol** (19 concurrent SVA invariants, mutation-validated), and
(b) is **self-consistent** across one directed scenario per bus-cycle type plus a
corner per fixed defect (76 directed checks). Burst order matches Developer's
Manual Vol.1 Table 6-12; pin semantics match datasheet 241997-010 Table 2.

True silicon-exact validation (layer 2 "bus-visible Pentium-compatible" of
**REF.md §4**) requires **real-chip / logic-analyzer / FPGA bus-tracer traces**
of ADS#/BRDY#/NA#/CACHE#/KEN#/HITM#/LOCK# (REF.md §4 measurement setup; §7 item 5
"Bus/protocol tests"). Until such traces exist, treat `biu_p5` as a
protocol-correct, self-consistent model — **not** a cycle/pin-exact replica — and
do not claim differential bus equivalence for M5B.

### 5.4 Integrated-bus caveat: `biu_p5` is a PROTOCOL EXERCISER, not a data path

The block above describes the **standalone** `biu_p5`. When `biu_p5` is wired into
`rtl/` via the gated bus subsystem (`rtl/bus/biu.sv`, run with `--bus-mode` /
`bus_mode=1`), it runs strictly as a **protocol exerciser** — it is **not** a
faithful external memory data path. This is the single most important pin-level
fidelity caveat for the integrated CPU, and it is exactly what the code comment in
`rtl/bus/biu.sv:25–62` states. Make it explicit here so the integrated mode is
never overread:

1. **The pins do NOT carry the data the core consumes.** The core's data and ack
   come **combinationally** from the back-side memory model (`mem2_*`), fully
   independent of `biu_p5`. That combinational path — not the pin data — is what is
   verified func-equivalent against the QEMU golden. `biu_p5` runs the real
   ADS#/T1/T2/BRDY# pin protocol **in parallel** on the same request so its SVA can
   be checked on real core traffic, but **there is no guarantee that the address
   `biu_p5` drives on its pins and the word the loopback returns on `d_in`
   correspond** (`rtl/bus/biu.sv:31–40`): because the core gets a combinational ack
   it advances before `biu_p5`'s registered `req_ack` pulses, so the responder
   generally replays the core's *subsequent* (not current) back-side word. "The
   data round-trips through the real pin protocol" is true only in the sense that
   *some* real back-side word traverses `d_in` — it does **not** mean the returned
   word matches the address on the pins or the word the core consumed.

2. **Single, non-burst, non-pipelined cycles only.** The integrated loopback
   responder holds `KEN#` deasserted (so `biu_p5` never upgrades a read to a 4-beat
   line fill), never asserts `NA#` (no pipelining), and never asserts
   `HOLD/BOFF#/AHOLD/EADS#` (`rtl/bus/biu.sv:54–62`). The integrated traffic is
   therefore **single-cycle bridging only**.

3. **Burst / pipelined / locked / snoop / backoff / arbitration are validated
   STANDALONE ONLY.** Because integrated mode never exercises those paths (point 2),
   the burst line fill, pipelined (`NA#`/T12/T2P), locked-group (`LOCK#`/`SCYC`),
   inquire/snoop (`AHOLD`/`EADS#`/`HIT#`/`HITM#`/writeback), `BOFF#` backoff, and
   `HOLD`/`HLDA` arbitration behavior remain validated **only** by the standalone
   self-consistency gate (`make bus` → `verif/bus/run.sh`: 19 SVA + 76 directed
   checks). They are **not** reached by the in-system `bus_mode=1` run.

4. **No pin-level cycle oracle in either mode** (§5.3). The integrated run makes a
   **functional** equivalence claim (combinational data path vs QEMU) plus a
   **protocol-SVA** claim (the FSM obeys the documented sequencing on real core
   traffic). It makes **no** cycle/pin-exact timing claim through the bus.

#### The integrated SVA corpus command (closing the "build-only `rtl-sva`" gap)

`make -C verif/tb rtl-sva` only **builds** the SVA-assertion-enabled integrated
model (`obj_dir_sva/tb_ventium`); a green build can be **misread** as "the
in-system SVA passed" when in fact nothing has run. The single command

```
verif/bus/run_busmode_sva.sh        # orchestrator wires: make bus-sva
```

removes that ambiguity. It (1) builds the SVA model via the `rtl-sva` target, then
(2) runs the **same 12-program `bus_mode=1` corpus** as `run_busmode_corpus.sh`
through the assertion-enabled binary with the 19 mutation-validated `biu_p5`
protocol SVA (`verif/bus/biu_p5_sva.sv`) **bound live** into the integrated
`biu_p5`. A program passes only if **(a)** no SVA fires — a fired Verilator
`--assert` aborts `tb_ventium` non-zero and logs `Assertion failed`, which the
script reports as a distinct `SVA-FAIL` — **and (b)** it is func-equivalent vs
QEMU (`compare.py --mode func` exits 0). The script prints a single
`BUS-SVA-OK` / `BUS-SVA-FAIL` verdict with a matching exit code. Per points 1–4,
this proves the documented protocol holds on real (single-cycle, non-burst,
non-pipelined) core traffic and the data stays func-equivalent on the independent
back-side path — it does **not** extend any cycle/pin-exact or
burst/pipelined/snoop claim to integrated mode.
