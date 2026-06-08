# +VEN_DEC_PIPE — decode-stage pipeline design (the byte-window MUXF lever)

The one RTL lever P0-8/P0-9 named after exhausting every tooling/floorplan option:
pipeline the single-cycle dual-issue x86 decoder so the **12×32:1 byte-window
alignment muxes over the 256-bit cache line** (the level-5 MUXF congestion, ~12.4 K of
14.5 K MUXF7, 43 % of the core, won't route below 22 ns) leave the combinational
critical cone. Synthesised from a 6-agent design workflow (`wf_84e2ef64`, 2026-06-08).
Layered on `+VEN_IC_BRAM`; default build (no macro) byte-identical.

## The congestion being removed
S_PIPE today does, every clock, combinationally: `eip → flin → ic_byte(flin+i)` for 6 U
bytes + `ic_byte(flin+u_d.len+i)` for 6 V bytes — each `ic_byte` is a 32:1 shift of an
8-bit slice out of a 256-bit line (+ a 2-line A/B select). That's twelve 32:1-over-256
muxes feeding decode → pairing → datapath → the `eip = eip+lenU+lenV` adder, all in one
cone with an `eip_reg→eip_reg` self-loop (16.8 ns: 6 ns logic / 10.8 ns routing = 64 %
routing from the cross-die MUXF fan-out). No directive can rearrange a fixed cone.

## The pipeline (decoupled PF → D1 → D2 + byte-aligned circular queue)
Insert a prefetch unit + a byte queue between the icache line buffers and the decoders:
* **State:** `pfpc` (prefetch PC, distinct from architectural `eip`); `iq[16][7:0]` byte
  queue contiguous in fetch order (16 = max U(6)+V(6)+4 slack); `iq_head/tail/count`
  (mod-16); D1 regs `d1_ub[6]`/`d1_vb[6]` (the 12 ALIGNED bytes) + `d1_lenU`/`d1_flin`/
  `d1_valid` + registered predict bits.
* **PF (prefetch, own PC, off the eip loop):** while `iq_count ≤ 12`, shift one icache
  WORD (4 bytes at `pflin[4:2]` — an **8:1 word select** + the line-buffer 2:1, NOT the
  32:1 byte shift) into `iq` at `iq_tail`; `pfpc += 4`. Word-granular, sequential.
* **D1 (align/length):** read 12 bytes from the queue at `iq_head` (12× **16:1 over 16
  flops**, feed-forward, terminates at the D1 register); run `fp_len` to locate V; capture
  the U window `iq[head..+5]` and the V-candidate window `iq[head+lenU..+5]` into
  `d1_ub`/`d1_vb` on the edge. The V index is a small mod-16 add, not a 256-bit re-address.
* **D2 (decode+issue+commit):** the full `decode`/`issue_uv` instances run on the
  REGISTERED `d1_ub`/`d1_vb`; the existing `core_fastpath.svh` issue arm commits VERBATIM.
  On issue, advance `iq_head += lenU+lenV` and `eip += same`. **The eip adder now consumes
  a D1-registered window → the eip self-loop no longer threads the 256:1 byte mux → the
  16.8 ns loop is CUT.** The 12×32:1-over-256 mass is replaced by an 8:1 word select
  (prefetch) + a 16:1-over-16-flop select (D1), both off the feedback recurrence.

Throughput is preserved (the queue drains by `lenU+lenV`/clock while prefetch refills
4 B/clock; D2 issues a pair every clock); the +1 pipe latency is a one-time fill at
loop/redirect entry. **Straddle is trivialised** — the queue linearises the 32-byte line
boundary at prefetch time, so the decoder never sees a boundary.

## Redirect (the +1 bubble, hidden by reused +VEN_IC_BRAM machinery)
* **Mispredict:** flush queue+D1, `pfpc<=redir_tgt`; the +1 pipe-fill clock is **ABSORBED**
  into the existing `mispred_bubbles` (3 U / 4 V cond) — the flush overlaps the first
  bubble. mispred_bubbles stays 3/4 (MANDATORY — else brrandom blows up).
* **Predicted-taken (brloop/nearbr back-edges):** key `pf_redir` on the D1-stage
  predict bits so the target line is resident + the prefetch enqueues target bytes a clock
  ahead → 0 added bubbles (preserves brloop +0.23 %, accimm/rmimm/sh1 +0.39 %).

## Build order (de-risked spike; each step independently gated, all behind +VEN_DEC_PIPE)
1. **Scaffold + `fp_len`** — length-only sub-decoder (strict projection of fp_decode.len),
   exhaustively proven `fp_len==fp_decode.len` over all (b0,b1,cyc). ✅ DONE
   (`ventium_decode_pkg::fp_len`, `verif/decpipe/run-fplen-gate.sh` → FPLEN-GATE-OK;
   default build 75/75 byte-identical). The #1 silent-bug footgun is guarded.
2. **Prefetch unit** ✅ DONE — a free-running 16-byte sliding-window queue (`iq`/`iq_cnt`/
   `iq_base`/`pfpc` under `+VEN_DEC_PIPE`, core.sv); read offset `iq_head = flin - iq_base`
   derived COMBINATIONALLY (no one-cycle lag, no next-eip weaving); prefetch refills ahead
   + slides the base toward flin + flushes on redirect; decode STILL on the old path. The
   sim-only MIRROR assertion (`iq[head+i]==ub/vb` while `iq_covers`) held with ZERO trips
   across all 20 bands + 75 func programs + a Quake 200k lockstep (EQUIVALENT); zero cycle
   change; default build byte-identical.
3. **D1 capture** — register `d1_ub`/`d1_vb`, still issue from the live window; assert
   `d1_ub==ub`. No cycle change.
4. **D2 switch + cut loose** — route decode/issue_uv from the REGISTERED window; advance
   iq_head+eip; then cut pfpc loose. Gate: func 75/75 + throughput bands (indepadd/accimm/
   rmimm/sh1) return to <1 %.
5. **Redirect/flush + mispredict absorb.** Gate: brloop/nearbr/brrandom + Quake <10 %.
6. **Speculative predicted-target queue refill** (zero back-edge bubble).
7. **Straddle + I-miss charge at prefetch** (pflin). Gate: mb_imiss in band.
8. **FULL GATE + the GO/NO-GO ROUTE PROBE** — func 75/75 + 20 bands + Quake; default
   byte-identical; THEN OOC synth+place+FULL ROUTE at a meetable clock (not a placer
   estimate — P0-9 proved they lie by ~10 MHz). **Success = spine F7/F8 collapses,
   congestion < level-5, design ROUTES LEGALLY below 22 ns.** This step is the verdict.
9. (contingency) If a band can't be fixed by prefetch widening / the absorb, add a +1
   pipe-depth term to the p5trace mispredict model (sanctioned: real P5 PF→D1→D2 latency).

## Kill criterion (the honest go/no-go)
Build steps 1–4 (bit-exact + throughput restored), then run step 8's route probe EARLY.
If the MUXF collapses + routes < 22 ns → finish band validation, bank a real 50–66 MHz
path. If congestion merely RELOCATES (likely to the D2-decode or FP-commit cone) and it
still won't route < 30 ns → keep `+VEN_DEC_PIPE` as a validated, removable option (like
`+VEN_IC_BRAM`), bank the ~45 MHz OOC closure, and defer 66 MHz to a second cone-removal
iteration / full-SoC. Measure, do not assume.

## Top risks
* The core bet: congestion may RELOCATE rather than clear (step-8 full route is the test).
* `fp_len` divergence (guarded by the step-1 exhaustive gate + step-2 queue mirror).
* The mispredict +1-bubble ABSORB must be exact (brrandom is the canary; +1 added not
  absorbed → +15-25 %, a reject).
* Prefetch-rate adequacy on long-insn bands (indepadd/accimm canaries; widen if drained).
