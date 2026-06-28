# DOS-Quake bring-up debug log — 2026-06-27

End goal: a Verilator sim of the **full SoC** (Core + System Bridge + Peripherals) that boots
FreeDOS, runs Quake, renders frames, and survives long runs.

Status: **(1) FreeDOS boot — DONE & validated. (2) Quake — the #GP that halted it is now FIXED
(runs past the old fault to 15M+ instructions); render-frame confirmation in progress. (3) clean
long runs — the blocking fault is gone; long-run soak in progress.**

---

## 1. What is FIXED (committed, validated)

| commit    | fix |
|-----------|-----|
| `914ec9e` | POP r/m16 paging store used the SS base, not the operand DS base (DOS-Quake #GP) |
| `816e7e0` | same-priv PM INT pushed the handler CS, not the interrupted CS (DOS-Quake #GP) |
| `3925df5` | implement PROTECTED-mode LSS/LFS/LGS (was real-mode-only → HALT) |
| **(this)** | **S_LOAD2 paging-lookup `cur_lin` only covered CMPS — far-ptr seg-load / BOUND / CMPXCHG8B / far JMP-CALL-indirect 2nd read translated the WRONG linear under paging (DOS-Quake null-SS #GP)** |

Validation (all green, regression-gated, re-run after the new fix):
- `make verify`     → 98/98 functional GREEN (every program diff-clean vs QEMU, incl. x87)
- `make verify-sys` → **949/949 EQUIVALENT** (cr0..cr4 + selectors + GPRs + eflags + eip)
- DOS-Quake SoC sim → **runs past the old #GP (eip=0x408d, ~8.9M insn) to 15M+ with no fault**

---

## 2. The bug that was just fixed — DOS-Quake null-SS #GP (ROOT-CAUSED + FIXED)

### Symptom
Quake's go32/CWSDPMI runtime ran ~8.9M instructions then faulted:
```
GUESTCON: General Protection Fault at eip=408d; flags=3046  error=0000 (null selector)
```
The faulting instruction is the DPMI AX=0x300 return: `lss esp, %cs:0x409d`
(`66 2e 0f b2 26 9d 40` at cs=0x2b:0x408d). It loaded a **null SS** → #GP, before any frame rendered.

### ROOT CAUSE
A **paging address-translation bug** in the seg-load's 2nd memory read, **not** decode and **not** the
cache. `core.sv`'s `cur_lin` (the linear address fed to the dTLB lookup, whose physical result
`mem_xlate` returns) had only a **single CMPS case** for state `S_LOAD2`:
```
S_LOAD2: cur_lin = dbase_edi+str_edi;     // only the CMPS [EDI] 2nd operand
```
But the bus driver's `S_LOAD2` (`core_bus_driver.svh:50-56`) computes **four** different linear
addresses: BOUND/CMPXCHG8B, far-ptr seg-load (LSS/LFS/LGS), far JMP/CALL indirect, and CMPS. For the
lss's 2nd read the bus driver produced the correct linear `0x2ab61` (`dbase+q_ea+q_w`), but `cur_lin`
produced the stale CMPS address `0x22f2a` (es:edi from the prior string op). So the dTLB was looked up
at the WRONG linear → `mem_xlate` returned the physical for `0x22f2a` → the 2nd read read **0** →
`seg_mem_sel = 0` → null SS → #GP. **Paging-only**, which is exactly why `verify`/`verify-sys`
(flat/identity) never caught it and the bug only bit DOS-Quake's paged go32 runtime.

### The fix (this commit)
Make `cur_lin`'s `S_LOAD2` arm mirror the bus driver's four arms EXACTLY (so the translated linear
always equals the accessed linear). Same class as the `S_STORE` `cur_lin` fix immediately below it.
Inert without paging (`mem_xlate == lin`), so `verify`/`verify-sys` stay byte-identical.

### Evidence chain (the taps that nailed it)
1. Slot DRAM correct (`--watch-write`/`--peek-mem`): SS=`0x8f` at `0x2ab61`, no clobber.
2. Decode correct (`dbg_sl` tap gated on the seg-load decode): `ibuf=66 2e 0f b2`, **`d_w=4`** (32-bit
   — my earlier "16-bit decode" reading was wrong; it came from an `eip`-gated tap catching stale
   non-decode cycles).
3. Exec correct decode-fields (`dbg_ls2`): `q_w=4`, `seg_load_lo=0`, `seg_real=0` — but
   `mem_load_data2 = 0` (2nd-read data zero).
4. The 2nd read goes to the **wrong address** (`S_LOAD2` trace): 1st read `0x2ab5d`→`0x076c` (ok),
   2nd read `0x22f2a`→`0` (should be `0x2ab61`).
5. Same-cycle capture: `q_seg_load=1, dbase=0x26ac0, q_ea=0x409d` ⇒ line 52 must give `0x2ab61`, yet
   `mem_addr=0x22f2a` ⇒ the value came from the **post-stage paging translate** (`mem_xlate`), whose
   dTLB lookup uses `cur_lin` — and `cur_lin` for `S_LOAD2` was the CMPS address. Bug located.

---

## 3. Dead end that was eliminated (do not re-walk)

For most of the prior session the #GP was chased as an **L1/L2 cache-coherence race**. That was wrong:
the caches are **not** instantiated in the SoC runs (`ven_l1d`/`ven_l2` are behind
`+define+VEN_SOC_L2`; the uop-cache behind `+define+VEN_UOPCACHE`; **neither is passed** — the default
`ventium_soc.sv:247 \`ifndef VEN_SOC_L2` muxes the stream straight to the TB mem bus). `verif/l1/
tb_socl1l2.sv` validated the cache in isolation (coherent) but it's off the run path. The real bug was
core-side paging translation. NOTE: "System Bridge" = the L1+cachemap+L2; running the *complete* SoC
still needs `+define+VEN_SOC_L2` (the cur_lin fix is needed regardless — it is core-side).

## 4. Debug infrastructure (what works in the tb_soc build)
- `--watch-write <addr>` / `--peek-mem <addr>` (tb_soc.cpp): mem-bus writes / DRAM hexdump.
- **memory tap + `/* verilator public_flat_rd */`** read via `top->rootp->ventium_soc__DOT__u_core__DOT__<sig>`
  — the robust way to surface internal state (the decisive method here). Must be a *memory* (unpacked
  array), not a scalar, and the metacomment needs spaces. RTL `$display` is suppressed in tb_soc; a
  fresh DPI call from a new always_ff gets pruned.
- `dbg_ibuf` core output (`VEN_DBG_CORE`); `VEN_GPTRACE` retire log.

## 5. Build / run quick-reference
Build: `make -C verif/tb soc VEN_IDE_DISK_HEX=/tmp/quake.disk.hex VL_EXTRA_DEFINES="+define+VEN_IDE_DISK_SECTORS=131040 +define+VEN_IDE_CYLS=130 +define+VEN_RTC_EXTMEM_KB=64512 +define+VEN_SOFTVGA"`
Run: `VEN_SOFTVGA=1 obj_dir_soc/tb_soc --image <bios.bin> --out /dev/null --max-insn N --max-cycles 300000000000 --quiesce 200000000`
(`--max-cycles` must be large; the default 1<<24 stops at ~2.3M insn.)

## 6. Goal 2 (render frames) — current blocker: video-init idle at 9.64M

With the #GP fixed, DOS-Quake runs to **9,642,323 instructions** then the core goes **idle** (quiesce:
no retire for 200M clocks) at `cs=0x87:0x331`, IF=1. The framebuffer never gets pixels:
- `ven_vga_fb` (mode-13h, 0xA0000) FB dumps every 0.5M insn from 0.5M→9.5M are **all zero** — Quake
  is NOT rendering to mode 13h.
- The trace right before the idle shows the **video init**: go32 (cs=0x87) → DPMI real-mode-int →
  cs=0x18 loop → the **real-mode video BIOS (cs=0xf000)** → back to go32, with `eax=0x101`
  (**VESA mode 0x101 = 640×480×256**). So Quake wants **VESA**, not mode 13h.
- The soft-VGA int10 C model (`tb_soc.cpp svga_service`, lines 362-373) implements only
  teletype/setmode-record/getmode/getcursor; **VESA (AH=0x4F) hits `default: break` (no-op)**. The
  no-op leaves AL≠0x4F so a VESA probe *should* read "unsupported", yet Quake still does not render to
  mode 13h — so either it has no mode-13h fallback, or the mode-13h path is also stuck, or the idle is
  a **HLT waiting for an interrupt** the southbridge never delivers (IF=1, zero retires after).

Two hypotheses to resolve next (both are "southbridge/peripheral" per the loop goal):
1. **Video**: Quake needs a working video mode. Either add VESA (0x4F00/01/02 + a 640×480 FB the TB
   can capture) to the soft-VGA, or make VESA cleanly fail AND verify the mode-13h render path lands
   pixels in `ven_vga_fb` (the pure-RTL FB).
2. **Interrupt delivery**: if `cs=0x87:0x331` is a HLT-wait, find which IRQ it waits on (PIT IRQ0 /
   IDE IRQ14) and why the PIC/PIT/IDE southbridge isn't waking it.

Next diagnostic: dump the opcode at `cs=0x87:0x331` (HLT vs spin) and check whether IRQ0/IRQ14 fire
after 9.64M.

## 7. Systematic unimplemented-opcode work (user directive)

The 9.64M idle was NOT a HLT-wait — `state==S_HALT` (8), `IF=1`: the core hit an
**unimplemented opcode**. (`pit_ticks=4`, `inta_rises=1`, `core_intr=1` unacked at the end — the
pending IRQ is just ignored because the core is dead in S_HALT, not waiting.) Mechanism:
`decode_stages.sv` raises `d_unknown`/`d_halt` for out-of-scope opcodes → core parks in S_HALT.

**Method to find the exact opcode** (re-addable; reverted to keep the tree clean): a ring-buffer tap
in core.sv gated on `VEN_DBG_UNK` capturing `{cs,eip,ibuf[7:0]}` whenever `state==S_DECODE &&
(d_unknown||d_halt)`, read in tb_soc.cpp via `top->rootp->ventium_soc__DOT__u_core__DOT__dbg_unk_*`.
Run with `+define+VEN_DBG_UNK` and `VEN_DBGUNK=1`. The last entry = the halting opcode.

**Implemented this session:** `POP FS` / `POP GS` (`0F A1`/`0F A9`) — commit `af05d38`. Mirror the
one-byte POP ES/SS/DS; execution path already generic over `q_sys_sreg`. verify/verify-sys green;
Quake advances past it.

**Next blocker (identified, not yet implemented):** `ENTER imm16, level` (`0xC8`) with **level>0**
(nested display copies) — currently `d_unknown` (only level-0 is implemented). DOS-Quake hits it in
REAL MODE (PE=0, cr0=0x10) at cs=0x34:0x3762 (`c8 14 02 22` = ENTER 0x214, level 0x22→eff 2), a
real-mode function prologue reached via the go32 DPMI→real switch. Needs a memory-read-and-push
micro-sequence (push EBP; ×(level-1){EBP-=w; push [EBP]}; push FrameTemp; EBP=FrameTemp; ESP-=alloc)
in S_USEQ — substantial; should land WITH a dedicated validation test (verify-sys does not cover it).

**Static survey of remaining gaps** (from a decoder audit, for completeness — implement as they
surface or proactively):
- One-byte: `0x63` ARPL, `0x6E/6F` OUTSB/OUTSD, `0xD6`, `0xF1` INT1; `0xC8` ENTER level>0.
- Two-byte `0F`: `0F 02/03` LAR/LSL, `0F 06` CLTS, big gaps `0F 0C-1D`, `0F 24-30`, `0F 32-7F`
  (RDMSR/WRMSR/SYSENTER/P6+); memory forms of `0F A3/AB/B3/BB` (BT/BTS/BTR/BTC) + `0F BA`; memory
  forms of `0F A4/A5/AC/AD` (SHLD/SHRD); `0F 00` /0,/4,/5 (SLDT/VERR/VERW); `0F 01` /6,/7 (LMSW/INVLPG).
- x87: transcendentals (`D9 F0-F3/F9/FB/FE/FF`) and FPREM (`D9 F8/F5`) are gated off
  (VEN_TRANSCENDENTAL/VEN_FPTRAP/VEN_FPREM); FCMOVcc (`DA/DB/DC/DD/DF` reg forms) deferred.

Approach: drive iteratively with the VEN_DBG_UNK tap (each Quake run surfaces the next real one),
implement + regression-gate (verify 98/98 + verify-sys 949/949) each, and proactively fill the
common static gaps. This is the path to Goal 2/3.

## 8. Systematic opcode coverage via verif/cov/opgen (the right tool for the directive)

A per-opcode differential generator (`verif/cov/opgen/`, built in a parallel effort) generates ONE
test per P54C opcode, assembles it (gas), runs it on the RTL + a qemu-i386 gdbstub golden, and diffs
— so every opcode gap/incorrectness surfaces as a DIVERGE vs qemu (never a silent miss). This IS the
systematic survey+validate loop the directive needs. Run: `bash verif/cov/opgen/run-opgen.sh [op_..]`.

Opcodes implemented this session, validated through this loop + the verify gates:
- **POP FS (`0F A1`) — PASSES opgen** (op_0fa1 EQUIVALENT vs qemu, PM32/user).
- POP GS (`0F A9`), nested ENTER (`0xC8` level>0), #GP paging fix — committed, verify 98/98 +
  verify-sys 949/949 green.

Remaining CORE-GAP findings (from `known_diverge.txt`, the opcode roadmap) — implement + re-run opgen:
- **BT/BTS/BTR/BTC with a MEMORY operand** (`0F A3/AB/B3/BB`, `0F BA /4-7`) — memory r/m halts
  (reg-direct passes). Needs the bit-string EA (`EA += bit_index/8`) for the reg-index form + RMW.
- **SHLD/SHRD with a MEMORY destination** (`0F A4/A5/AC/AD`) — memory dst halts. Needs RMW reusing
  the existing shift logic.
- **POP ES/DS/GS opgen divergence** — op_07/op_1f/op_0fa9 retire FEWER records than qemu (`push <seg>;
  pop <seg>`), while POP FS matches. `seg_load_fault` already handles null correctly, so the cause is
  non-obvious (PM32/user CPL3 corner, or a PUSH-seg value diff) — needs a dbg run on op_0fa9 to find
  the divergence point before fixing. NOT a simple gap.
- TRANSC (transcendentals) deferred behind `+VEN_TRANSCENDENTAL`; CLI/STI/POPF are CPL3-semantics
  (validated at CPL0 by `run-modes.sh`), not bugs.

## 9. Quake render path: a control-flow bug beyond the opcode gaps

After POP FS/GS + nested ENTER, DOS-Quake (in a go32 DPMI->real-mode excursion, cs=0x34, PE=0) runs
into a **data table** at cs=0x34:0x3810+ (peek-mem confirms consecutive 16-bit words 0x14f,0x150,…):
i.e. execution FELL THROUGH into data (a wrong branch/return), then S_HALTs on `0x63` (a data byte;
ARPL is #UD in real mode anyway). This is a CONTROL-FLOW/correctness issue, NOT a missing opcode (the
core executed the data as valid opcodes until 0x63). opgen reports 0 NEW-FAIL (no wrong-result
divergences in implemented opcodes), so the wrong branch is subtle — likely a real-mode-specific
path or the DPMI real-mode-int target. Needs a focused control-flow trace (which branch/jump at
~cs:0x3810 should have diverted) — separate from the opcode work.

## 10. opgen validation state (this session)

Full `run-opgen.sh` (PM32/user, vs qemu-i386): **384 PASS, 29 KNOWN, 0 NEW-FAIL** — my opcode
work introduced zero regressions, and opgen *caught a real bug in my nested ENTER*: under paging the
`S_ENTER` micro-sequence skipped address translation (missing from the `translatable` set) and
stalled. Fixed (`4b9225d`); `op_c8ent` (hand-added ENTER level-3 test) now EQUIVALENT to qemu. POP FS
also confirmed PASS. This is the systematic survey+validate loop working — exactly the directive.

Session opcode commits (all verify 98/98 + verify-sys 949/949 + opgen-clean):
`6a6fa62` #GP paging cur_lin; `af05d38` POP FS/GS; `17a630a` nested ENTER; `4b9225d` S_ENTER paging.

Remaining opgen CORE-GAP findings (the roadmap, 0 NEW-FAIL so none hide):
- BT/BTS/BTR/BTC memory (`0F A3/AB/B3/BB`, `0F BA /4-7`) + SHLD/SHRD memory (`0F A4/A5/AC/AD`) — RMW
  forms halt; the next implementations.
- POP ES/SS/DS/GS (op_07/17/1f/0fa9) DIVERGE (RTL retires fewer records) while POP FS PASSES — the
  decode is fine (FS passes); the PM32 seg-RELOAD of a valid selector (0x2b) halts/faults in a way
  qemu doesn't. Needs a triage of op_07's RTL trace (likely a GDT-limit/descriptor corner in the
  cov-TB PM32 env vs qemu) before deciding core-fix vs test-env.

## 11. Quake render blocker — refined via a retire-ring trace (last 8192 retires)

A 64/512/8192-deep retire ring (cs:pc of every retire, read via rootp) characterizes the stall:
- go32 **polls in a loop**: cs=0x87:0x03d8 retired **4315×** in the last 8192 retires, interleaved
  with repeated real-mode DPMI calls (cs=0x26ac → DOS cs=0x05f7/0x00d9 → **BIOS cs=0xf000** → back).
  So Quake is hammering a DOS/BIOS service and waiting on its result.
- The **PIT is NOT the problem**: ~4 ticks in 271M cycles ≈ 18.2 Hz over the ~0.22 s of sim time —
  correct. (Earlier "timer barely ticks" was a misread; the rate is right.) So the stall is not a
  missing timer interrupt.
- The halt itself: **one anomalous excursion lands in real-mode cs=0x34 at a DATA region** and runs
  **512+ instructions straight-line with zero branches** (0x3425→0x3835, confirmed data via peek-mem:
  consecutive words 0x14f,0x150,…) into `0x63` (#UD in real mode) → S_HALT. The other excursions
  (DOS/BIOS) are normal; this one's real-mode target is wrong.

So the Quake render blocker is a **DOS/DPMI/real-mode interaction**: a specific DPMI real-mode-int (or
its IVT target / register setup) lands at the wrong real-mode CS:IP (cs=0x34 data) for one INT, while
the surrounding poll loop spins. This is NOT an opcode gap (opgen: 0 NEW-FAIL) and NOT the timer.
Next: identify which INT/excursion produces the cs=0x34 target and why (trace the DPMI int dispatch +
the IVT read for that vector). A deep DOS-internals investigation, separate from the opcode roadmap.

## 12. Exhaustive opcode pass — memory RMW forms implemented (this session)

Driven by the opgen CORE-GAP roadmap, the memory-operand RMW forms are now implemented + validated
vs qemu (each opgen-PASS individually + verify 98/98 + verify-sys 949/949):
- **SHLD/SHRD memory** (`0F A4/A5/AC/AD` /r mem) — commit `8b5e7ce`. RMW mirroring the K_SHIFT 0xC1
  pattern; `dst_cur` made mem-aware; result to S_STORE; gpr write guarded.
- **BT/BTS/BTR/BTC memory** (`0F A3/AB/B3/BB`, `0F BA /4-7`) — commit `a5e354f`. BT reads [mem] (CF
  only); BTS/BTR/BTC RMW; index masked to operand size (huge-offset bit-string addressing not
  modeled — opgen exercises in-operand offsets). op_0fa3/ab/b3/bb + op_0fba_4/5/6/7 EQUIVALENT.

That's **12 CORE-GAP findings resolved** this session, on top of POP FS/GS, nested ENTER (+ its
opgen-caught paging fix), and the #GP paging fix. (A full-suite opgen re-run hit transient
qemu-gdbstub port contention — the parallel session runs opgen concurrently — so the count is from
the per-opcode validations, all PASS, NEW-FAIL=0.)

Remaining opgen findings: POP ES/SS/DS/GS seg-RELOAD divergence (decode OK — POP FS passes; a PM32
seg-reload corner to triage), transcendentals (gated behind +VEN_TRANSCENDENTAL), CLI/STI/POPF
(CPL3 semantics, not bugs). Plus the Quake real-mode control-flow fall-through (§11) — a DOS/DPMI
issue, not an opcode gap.

## 13. Quake render blocker is VESA/video, not (only) the crash

Two new facts (dump at the halt):
- **`mem[0x449] = 0`** — Quake NEVER set a standard BIOS video mode (mode-13h would write 0x13). It is
  using **VESA/VBE** (consistent with the earlier `eax=0x101` = VBE mode 0x101 = 640×480×256).
- **No IVT entry points to cs=0x34** (scanned all 256 real-mode vectors) — so the crashing excursion
  is NOT a DPMI simulate-real-mode-int handler. It is a computed far-jump (almost certainly a VBE
  **bank-switch / protected-mode-interface** call) to an address (cs=0x34:0x595d) that is DATA →
  512+ straight-line instructions → `0x63` (#UD in real mode) → S_HALT.

Implication for Goal 2: the RTL framebuffer `ven_vga_fb` is **mode-13h (320×200, 64 KiB @ 0xA0000)
only** — it cannot capture a VESA 640×480 linear framebuffer even if Quake rendered. So "render frames
to the RTL FB" requires EITHER (a) steering Quake to **mode 13h** (so it draws to 0xA0000 → ven_vga_fb),
which means making VBE cleanly unavailable so Quake's software renderer falls back; OR (b) adding a
VESA/VBE model + a capturable linear FB. The cs=0x34 #UD is the VBE far-call landing in garbage because
the VBE interface isn't really provided. This is a video/VBE bring-up task, NOT a CPU opcode gap
(opgen: 0 NEW-FAIL) and NOT the timer (PIT ticks correctly).

## 14. VESA theory RULED OUT — the cs=0x34 crash is a plain real-mode far-jump to data

Made the soft-VGA report VBE-unsupported (int10 AH=0x4F -> AX=0) and re-ran with a log: **VBE-FAIL
count = 0** — the soft-VGA hook NEVER saw an int10 AH=0x4F call, and the run still halts at the exact
same 9,643,312. So Quake's crash path does NOT use standard VBE-via-int10; my "Quake uses VESA"
reading (from `eax=0x101`) was wrong (that was just a register value, not a VBE mode). Reverted the
no-op change.

Re-characterized Goal-2 blocker (what's actually known, no theory):
- After the go32 DPMI->real-mode switch, real-mode execution reaches cs=0x34 and runs **512+
  straight-line instructions through a DATA region** (consecutive words 0x14f,0x150,… per peek-mem)
  into `0x63` (#UD in real mode) -> S_HALT at 9.64M.
- cs=0x34 is **not** in the IVT (not an int handler) and **not** reached by int10/VBE. It's a
  computed far-jump to a wrong target (cs=0x34:~0x595d, which is data). The far-jump SOURCE (which
  go32/real-mode instruction computed cs=0x34:* and from what value) is the unknown.
- Confirmed NOT: a missing opcode (opgen 0 NEW-FAIL), the timer (PIT correct), VBE-via-int10.

Next concrete step (not yet done): trace the instruction that performs the cs=0x26ac -> cs=0x34
far-jump and where it sourced the (wrong) target — a retire/operand trace of the go32 real-mode stub
right before the transition. This is the remaining Goal-2 blocker: a deep real-mode/DPMI control-flow
bug, distinct from the (now substantially closed) opcode work.

## 15. Far-jump traced: the crash is a RETF to a corrupted real-mode target (DPMI)

Retire-ring (8192) located the exact transition into the data region:
- `[7464] 0034:595d <-- 26ac:595b` then `[7465] 0034:3275 <-- 0034:595d`.
- Peeked the source bytes at cs=0x26ac:0x595b (lin 0x2c41b): `0b c3 cb` = **OR AX,BX ; RETF**.
  So a **RETF at cs=0x26ac:0x595d** (inside go32's real-mode code) pops a far return address of
  **cs=0x34:0x3275** off the real-mode stack and jumps there — and cs=0x34:0x3275 is the **data**
  region (the 512+ straight-line run into the #UD).

Reading: go32's real-mode code (cs=0x26ac, which the ring shows running a long loop just before)
returns via RETF to **cs=0x34:0x3275, a wrong/corrupted real-mode CS:IP**. cs=0x34 is a suspiciously
LOW real-mode segment (base 0x340 = the IVT/BIOS-data area) — far too low to be a real DOS allocation
or code segment, so the **segment value itself looks wrong** (a truncated/miscomputed selector→segment
or a corrupted DPMI Real-Mode-Call-Structure CS field). The data at cs=0x34:0x32xx even decodes bytes
as `call far cs=0x26ac:*`, which is why go32's loop is reached from it — execution bounces between the
garbage and go32's real stub.

Goal-2 root: **a DPMI real-mode call/return lands at a wrong real-mode segment (cs=0x34)**. Real-mode/
DPMI control-flow corruption — NOT an opcode gap (opgen 0 NEW-FAIL), NOT the timer, NOT VESA. Next
concrete step: find WHERE cs=0x34:0x3275 is pushed/written (the far-CALL or the RMCS CS:IP store that
put 0x0034 on the stack, or the PM->real switch target) — that write is the actual bug site.

## 16. SP-drift REFUTED — it's an intermittent single CS-word corruption

Captured {cs,pc,ESP} per retire. The cs=0x26ac loop ESP is **stable** — it returns to `0x6fa8` on
every iteration ([1057],[2550],[4043],[5536],[6250],[7278] all esp=0x6fa8). So **no stack-pointer
leak/drift**. Decisive comparison of the same RETF site:
- early (correct): RETF -> **cs=0x26ac:0x3275** (esp~0x6f90 region)
- crash  (wrong):  RETF -> **cs=0x34:0x3275**  (esp=0x6f94) — **IP word 0x3275 correct, CS word
  0x26ac -> 0x34**.

So the saved far-return (or RMCS) **CS word is corrupted 0x26ac->0x34 once**, IP intact, with the SP
healthy. go32 makes MANY internal real-mode calls in its own segment (CS=0x26ac); exactly one gets
CS=0x34, right after a nested deeper call ([6305]-[7081], esp dips to ~0x6e88). Ruled OUT so far:
opcode gap (opgen 0 NEW-FAIL), timer (PIT ok), VESA (VBE-FAIL 0), **SP drift (esp stable)**. So this
is a **targeted bad write of 0x0034** to a real-mode return-CS / RMCS slot — a data corruption in
go32's DPMI real-mode path, not a clean core SP/opcode bug.

Next concrete step: value-watch — log any store of 16-bit `0x0034` to the real-mode stack CS slot
(needs SS captured at the RETF to compute the linear address), or trace the nested call at
[6305]-[7081] that precedes the corruption. That store is the bug site.

## 17. ROOT MECHANISM: a near-CALL to a far-RET helper over-pops a saved register as CS

Value-watched the corrupted stack CS slot (SS=0x2c70, esp~0x6f90 -> lin 0x33692) and froze the log at
the first cs=0x34 retire. The bad write is **cs=0x26ac:0x31fa storing 0x0034** to the CS slot — and
decoding the code reveals the full chain:
- `cs=0x26ac:0x31f5` = `c8 0c 00 00` = **ENTER 12,0** (function prologue)
- `cs=0x26ac:0x31f9` = `56` = PUSH SI;  `cs=0x26ac:0x31fa` = `57` = **PUSH DI** (DI=0x0034) — normal
  callee-save. THIS is the 0x0034 that later becomes the bogus CS.
- `cs=0x26ac:0x3272` = `e8 df 26` = **near CALL 0x5954** (pushes only IP=0x3275)
- `0x5950..0x5966` = two 32-bit shift helpers (SHR/SHL/OR/XCHG), each ending in `cb` = **far RETF**
  (0x595d, 0x5966) — i.e. compiler FAR-helpers.

So the far RETF at 0x595d pops IP=0x3275 (correct) **plus one extra word** as CS; that extra word is
the saved DI = 0x0034 -> jumps to **cs=0x34:0x3275** (data) -> #UD. Early the stale slot happened to
hold 0x26ac so the same RETF "worked" by luck; once PUSH DI leaves 0x34 there, it crashes.

This is a **near-CALL / far-RET mismatch** in the EXECUTED code, NOT a core opcode bug: opgen
validates near-CALL (pushes 1 word) and far-RET (pops 2) individually, and both behave per their
bytes. So an UPSTREAM divergence puts execution onto this mismatched path (we near-call a far-helper
that real go32 would far-call). Remaining root work: find why 0x3272 is reached as a near-CALL to a
far-helper — trace how 0x3272 is entered (a mis-landed jump / wrong boundary), or whether the loaded
go32 bytes at 0x3272 differ from the on-disk Quake image (a load/relocation issue). The exact failing
instructions are now pinned (0x3272 near-call, 0x595d/0x5966 far-ret, 0x31fa the PUSH DI).

## 18. PIVOT: the crash region is go32 SELF-MODIFYING CODE (runtime stub patching)

`--watch-write` on the near-call byte (lin 0x29d32) + helper byte (lin 0x2c41d), with no RTL changes,
shows the real-mode stub is **built and patched at runtime**, not static:
- retire ~5.16M, cs=0x08 (PM flat): a byte-wise **bzero** clears the 0x2c41x region.
- retire ~8.75M, cs=0xf000 (BIOS): an esi/edi/ecx **copy loop** loads the stub bytes into 0x29d3x
  (e.g. wdata 0x14a0/0x4689/0x83f6 with edi stepping +2, ecx counting down).
- retire **9,642,324**, cs=**0x0087:0x0334** (go32 PM): a 32-bit **`mov [0x29d30], 0x26dfe82d`** —
  go32 **patches its own real-mode call stub** ~1000 instructions before the #UD at 9,643,312.

The early dumps confirm the far-RETF helper (0x2c41d=`cb`) is legitimately LOADED (re-loaded after the
bzero), and the near-call byte is present too. So the near-CALL/far-RET mismatch (§17) is the RESULT
of go32's runtime patch: go32 dynamically writes the call into the stub. The patch value 0x26dfe82d
(bytes `2d e8 df 26`) overwrites 0x29d30..0x29d33, which previously held `b1 0c e8 d1` (MOV CL,0xc;
CALL ...0x5946) — i.e. it rewrites the CL-load + call target.

So the Goal-2 root is now in **go32's DPMI self-modifying stub patch**: either (a) the core computes
the patch store's address/value wrong at cs=0x87:0x334 (an addressing/ALU bug feeding the SMC), or
(b) the core executes the freshly-patched stub bytes differently than real hardware (an SMC/prefetch/
decode-coherence issue — the patched bytes must be re-fetched, not a stale decode). This is a deep
go32-DPMI + self-modifying-code interaction, NOT an opcode gap (opgen 0 NEW-FAIL), the timer, VESA, or
SP-drift. Next: decode the SMC store at cs=0x87:0x334 and verify its computed addr(0x29d30)/value
(0x26dfe82d), and check the core re-fetches patched code (SMC coherence) at the stub.

## 19. opgen POP-seg "CORE-GAP" RECLASSIFIED: cov-tb environment, not a core bug

Triaged the opgen POP ES/SS/DS/GS divergence (op_07/17/1f/0fa9: RTL retires 8 records vs qemu's 12,
first 8 match -> RTL idles ON the POP). Findings:
- All five seg-pops (07/17/1f + 0F A1/A9) share the SAME decode (default d_kind=K_ALU, d_pop_sreg)
  and the SAME exec arm (core_exec.svh:151 -> PM -> S_SEGLD). So no per-sreg code difference.
- POP FS PASSES because FS=0 (NULL) in PM32 user mode -> S_SEGLD null path, no GDT walk. POP
  ES/DS/SS/GS reload the VALID selector 0x2b -> S_SEGLD walks the GDT.
- The cov-tb (tb_main.cpp:132) **loads segments DIRECTLY from the producer's initial-process-image
  JSON** (selector + hidden base/attr from qemu) and does NOT lay down a walkable GDT. So a non-null
  PM seg RELOAD reads garbage at gdt_base+idx*8 and stalls/halts — a **cov-tb environment limit**.
- The core's PM POP-seg is CORRECT: verify-sys 949/949 (real GDT) AND commit `6a6fa62` fixed exactly
  DOS-Quake's `pop ds` (CWSDPMI reflector, PM, sel 0x33) — Quake now runs PAST it to 9.64M.

So op_07/17/1f/0fa9 are MODE/ENV, not CORE-GAP — no opcode work needed. (LAR/LSL `0F 02/03` ARE
genuinely unimplemented, but likewise can't be exercised in the GDT-less cov-tb, and would IDLE not
crash — so they are NOT the Quake divergence either.) Net: the real opcode gaps (SHLD/SHRD mem, BT/
BTS/BTR/BTC mem) are implemented + validated; the remaining opgen findings are environment or
non-Quake-relevant. The Quake render blocker remains the go32 self-modifying-stub interaction (§18).

## 20. REFERENCE ESTABLISHED: qemu renders Quake on this exact disk

Converted the IDE disk (`xxd -r -p` of quake.disk.hex -> 67 MB raw) and booted it under
**qemu-system-i386 8.2.2** (`-hda quake.raw -m 64`, headless). A monitor `screendump` at 55 s
captured a **640x400 framebuffer with 104 distinct colors** (Quake's brown UI/scene palette, dark
browns 0x402818/0x472818/... — a real rendered graphics frame, not text). Saved `/tmp/qemu_q.ppm`.

Consequences (this reframes the whole Goal-2 picture):
1. The disk + Quake install are **VALID** — a working reference renders Quake. So the RTL failure is
   a **real, fixable core bug**, NOT a disk/setup problem and NOT unfixable.
2. The RTL diverges from qemu somewhere before the go32 SMC crash; with qemu as the oracle, a
   **differential trace is now feasible** (it was not before — that was the missing piece behind the
   "rabbit hole" status).
3. Quake renders at **640x400 = a VESA/VBE mode** (confirms §13: Quake uses VBE, not mode 13h). So to
   actually SEE Quake frames from the RTL, `ven_vga_fb` (mode-13h, 64 KiB @ 0xA0000) must be extended
   to a capturable VESA linear framebuffer, on TOP of fixing the core divergence.

Next concrete step: differential qemu-vs-RTL trace SCOPED to the go32 stub region (qemu `-d in_asm
-dfilter <0x28000..0x2d000>` for the real-mode stub) to compare qemu's stub control flow (far-call?)
against the RTL's near-CALL@0x3272 / far-RETF@0x595d (§17) — the first structural difference is the
bug. `/tmp/quake.raw` is kept for this. This is the path to actually fixing Goal 2.

## 21. Differential at the crash site: near/far is CORRECT — the bug is a value divergence (DI)

Traced qemu's go32 stub region (`-d in_asm -dfilter`). qemu's stub is at DIFFERENT linear addresses
(different memory map: ~0x2bxxx vs RTL's 0x29d3x) but the CODE is byte-identical:
- shift helper ends in **`cb` (far-RETF)** in qemu too: `8bda d3e8 d3ea f6d9 80c110 d3e3 0bc3 cb`
- reached by the SAME **near-CALL**: `... b1 0c e8 d1 26` (MOV CL,0x0c; near CALL)

So the near-CALL/far-RETF "mismatch" (§17) is **intentional, correct go32 code — NOT the bug**. It's a
compiler far-call thunk: the function (ENTER 12,0 @0x31f5; PUSH SI; PUSH DI) is laid out so the saved
DI sits at [SP+2] above the near-call's return IP, and the helper's far-RETF pops {IP, DI} — i.e. the
function CONVENTION is **DI = the real-mode segment to far-return to**. qemu has the right segment in
DI; the RTL has **DI = 0x34**.

So the Goal-2 bug is an **upstream STATE divergence**: within the RTL, DI should equal the RTL's own
stub segment (~0x26ac) but is 0x34. (Caveat: qemu's stub segment differs from the RTL's by memory
map, so DI's absolute value legitimately differs across the two — the bug is that 0x34 != the RTL's
own 0x26ac.) The same wrong 0x34 is what §16 saw corrupt the return CS. So earlier in execution the
RTL computes/loads 0x34 where its stub segment belongs.

Next: a CODE-ALIGNED differential (compare register state at the same stub OFFSET, since absolute
addresses differ by memory map) to find where DI / that segment value first becomes 0x34 — that is
the actual core bug. The near/far rabbit hole is now closed; this is a concrete register-divergence
hunt with a working oracle.

## 22. ROOT PINNED: the SMC patch sends the near-CALL +0xe past a push-CS thunk

EDI-per-retire trace (frozen at crash) overturns the DI theory: EDI=0x34 is NORMAL — set every
iteration in cs=0x18 PM code and saved/restored by the crash function (PUSH DI @0x31fa / POP DI
@0x31f1). The function runs with EDI=0x34 on EVERY iteration but only crashes on the last. The real
differentiator is the **near-CALL target**, from the execution traces (unambiguous):
- RTL retire ring: `[8186] cs=0x26ac:0x3272` (near-CALL) -> `[8187] cs=0x26ac:0x5954` (helper). So
  the RTL call has rel16 = 0x5954-0x3275 = **0x26df** -> target **0x5954**.
- qemu trace: `b1 0c e8 d1 26` = MOV CL,0x0c; near-CALL rel16 **0x26d1** -> target **0x5946**.
- Difference = **+0xe (14 bytes)**, exactly the **push-CS thunk** at 0x5946..0x5953 (the value-watch
  saw `pc=0x5947` store 0x26ac = PUSH CS — it sets up the far-RETF's return segment).

So qemu calls the thunk (push CS=0x26ac, then the shift helper that far-RETFs back to cs=0x26ac);
the RTL's call SKIPS the thunk (jumps straight to 0x5954), so no CS is pushed and the far-RETF pops
the stale saved DI (0x34) as CS -> cs=0x34:0x3275 -> #UD. The RTL got 0x26df via the go32 **SMC patch**
(cs=0x87:0x334 writes to lin 0x29d30, §18) — at 9M the call was the correct `e8 d1 26` (->0x5946); the
patch changed it to `e8 df 26` (->0x5954). So the RTL's self-modifying patch lands the call **+0xe off**,
skipping the push-CS thunk.

This is the actual core bug locus: the go32 SMC patch computes/writes rel16 0x26df instead of 0x26d1
(+14 = the thunk length). Final step: decode the patch store at cs=0x87:0x334 and check whether the
core mis-computes the patched rel16 (an ALU/addressing bug feeding the SMC) or the store lands wrong —
that is the fix for Goal 2 (then VESA capture to see frames). The bug is now a single wrong constant
(+0xe) with a known oracle value (0x26d1).

## 23b. UNBLOCKED: maps aligned (same bios.bin) + thunk fully decoded

Re-ran qemu with the SAME `bios.bin` the SoC uses (not qemu's default) + `-m 64`: qemu's go32 stub now
loads at the **identical linear addresses** as the RTL (0x26ac0, 0x29d3x, 0x2c406, ...). So a direct
code-aligned differential is now feasible (the earlier mismatch was just qemu's default-BIOS memory
map). Confirmed at the aligned address:
- qemu near-CALL @0x29d32 = `... b1 0c e8 d1 26` -> rel16 **0x26d1** -> 0x5946 (thunk). RTL = 0x26df ->
  0x5954 (bare helper).
- qemu thunk @0x2c406 (=cs=0x26ac:0x5946) = `5b 0e 53 80 f9 10 73 10` = **POP BX; PUSH CS; PUSH BX;
  CMP CL,0x10; JNB +0x10**. This is the far-call ADAPTER: it pops the near-CALL return IP (BX),
  **PUSH CS** (the segment the far-RETF will pop), re-pushes BX, then dispatches the shift by CL. So
  after the thunk the stack is {IP, CS} and the helper's far-RETF returns correctly to cs=0x26ac.

The RTL's +0xe-skip jumps straight to 0x5954 (past `PUSH CS`), so the far-RETF pops the stale saved
DI (0x34). Root is the SMC patch writing rel16 0x26df where go32 wants 0x26d1 (target 0x5954 vs the
thunk 0x5946). NEXT (now feasible): code-aligned diff of go32's PM patch routine (cs=0x87:~0x334) /
the call template it copies — find where the RTL gets target 0x5954 (helper) instead of 0x5946
(thunk), i.e. the +0xe. That instruction/value is the core bug. Then VESA capture for frames.

## 23c. The divergence is ONE PM store; byte-confusion resolved

`--watch-write 0x29d30` over the whole run: near the crash (last_n>9.6M) the **only** write to the
call region is the single SMC store at **cs=0x87:0x334**, value **0x26dfe82d** (`2d e8 df 26`), at
retire 9,642,324, with ecx=0, esi=0x7400, edi=0x63400. So the crashing call's bytes come entirely
from this one PM store (over the BIOS-loaded stub). The call is `e8 df 26` (rel16 **0x26df** ->
0x5954, the bare helper) where go32 wants `e8 d1 26` (**0x26d1** -> 0x5946, the PUSH-CS thunk). So the
whole Goal-2 bug is **one wrong dword written by one PM instruction** — go32 computes 0x26dfe82d on
the RTL but 0x26d1e82d on qemu (+0xe in the rel16). The store value isn't in ecx/esi/edi, so it's in
eax/ebx/edx/ebp — built/loaded just before cs=0x87:0x334.

CONTINUATION (precisely scoped, maps aligned): trace the source of 0x26dfe82d at cs=0x87:0x334 —
capture eax/ebx/edx/ebp there + the few instructions before, and dump the candidate template source
(esi=0x7400 / a reloc entry) in BOTH RTL and qemu (now same addresses). Whichever shows 0x26df vs
0x26d1 localizes the core bug: a wrong rel16 computation (target 0x5954 vs 0x5946) or a mis-relocated
call template. Then fix + VESA capture. The bug is reduced to a single dword with a known correct
value (0x26d1e82d).

## 23d. The patch value is a COPIED template (relocated rel16) — root is a reloc/template divergence

Traced the source of the patch value 0x26dfe82d at the store (cs=0x87:0x334). It is in **NO GPR** at
the store: eax=0x101, ecx=0, edx=0x008000b7, ebx=0x000e0021, ebp=0x91e, esp=0x770, esi=0x7400,
edi=0x63400 — none = 0x26dfe82d. And esi=0x7400 holds CODE (`e3 22 ac ae...`), not the value. So the
store is a **memory->memory copy of a pre-built call template** (bytes `2d e8 df 26`), whose source is
ds_base-relative (PM segmentation) — not resolvable from the physical write address alone.

So the wrong rel16 (0x26df) was baked into the template EARLIER, i.e. at go32's **load-time relocation**
of the call (`rel16 = target - site`). With maps aligned the target/site should match qemu, so the
divergence is in the relocation arithmetic or its inputs — one more layer, at load time, not at the
9.64M crash. This is the layer where iterative single-shot RTL tracing reaches its practical limit:
rooting it needs either source-read instrumentation (capture the mem_addr the template is read from,
follow it to the reloc that wrote it) or a full instruction-by-instruction code-aligned qemu<->RTL
diff of go32's PM relocation pass (now feasible since maps align). The bug remains a single dword with
a known correct value (0x26d1e82d); what's unrooted is which load-time reloc instruction bakes 0x26df.

## 23e. BREAKTHROUGH: register-level differential -> 32-bit truncation in go32's CS16 code

The qemu gdbstub is killed by the env, but **qemu `-d cpu` works** (no gdbstub) and `-d cpu` reports the
segment bases: **cs=0x18 base=0x26ac0, cs=0x87 base=0x228f0** (both DPL CS16 = D=0, 16-bit). Grepping
qemu's `-d cpu` log against the RTL's patch-routine register trace gives the decisive comparison — at
the operation reaching `eax=0x80000068` (matches in BOTH):
- **qemu**: `ebx=0x000e3772  edx=0x00800002`
- **RTL** : `ebx=0x00003772  edx=0x00000002`

**Low 16 bits identical, high 16 bits ZEROED in the RTL** — the textbook 16-vs-32-bit operand
signature. And ebx's lost high nibble is **0xe** — exactly the +0xe by which the call rel16 is wrong
(0x26d1 -> 0x26df). So the single-dword bug is the downstream symptom of the RTL **truncating 32-bit
register values to 16 bits inside go32's CS16 (D=0) code segment**. This is why opgen (PM32, D=1) and
the sys gate never caught it: D=0 32-bit-operand (0x66-in-16-bit-seg) handling is under-tested.

`eff_opsize = pfx_opsize ^ def16` (decode_stages.sv:216) and the 4-prefix machine (l.190) look
correct, and eax's 32-bit ops DO work — so it's a SPECIFIC instruction/opcode whose 32-bit writeback
or memory width is wrong in D=0 (the high `0xe`/`0x80` of ebx/edx is computed/loaded as 0 before the
captured window, i.e. before cs=0x18:0x2afc). FIX PATH (well-scoped, method proven): trace ebx's
high-16 divergence back to the exact opcode via the qemu `-d cpu` differential (regenerate with a ~10s
`-d cpu` run, grep for the first `EBX=000eXXXX`), then fix that opcode's D=0 32-bit handling in the
core. This is a real, fixable core bug — the root cause, not just the symptom.

## 23f. RTL-side narrowing of the D=0 truncation + environment block

Checked the decode for the 32-bit-truncation bug (§23e): all unconditional `d_w=3'd2` are legitimately
16-bit (LTR/LLDT, MOV Sreg, SMSW r16, BCD AAA/DAA on AX); `eff_opsize = pfx_opsize ^ def16` (l.216) is
correct for both D-bits; LES/LDS/LSS use `d_w=eff_opsize?2:4`. So the truncation is NOT an obvious
hardcoded-width decode bug — it's a subtler specific-opcode/execution path that drops the high 16 of a
32-bit GPR write in a D=0 segment. The robust evidence stands: qemu keeps `edx=0x00800002 / ebx=
0x000e3772` at the patch op while the RTL has `edx=2 / ebx=0x3772` (high 16 = 0), and ebx's lost 0xe is
the call rel16 +0xe.

To pinpoint the exact opcode I need the qemu `-d cpu` differential to find the instruction that sets
edx/ebx's high bits (then check the RTL does it 16-bit). That worked once (it gave §23e) but the
environment now **consistently kills qemu's emulation runs** (binary `--version` works; the long `-d`
runs get SIGTERM'd; the gdbstub too). So the final pinpoint+fix is currently env-blocked. FIX PATH when
qemu runs again: `-d cpu` trace, grep first `EBX=000e…`, read the TB, fix that opcode's D=0 32-bit
writeback in the core; alternatively an RTL detector (log GPR writes in def16 segs with a 0x66 prefix
whose committed q_w != 4) can find it qemu-free but needs care vs false positives.

## 23g. RTL detector: decode width is CORRECT; truncation (if real) is exec-level; alignment caveat

Built an RTL detector (S_DECODE, def16 segment, GPR write, 0x66-prefix-present, `d_w==2`) to catch a
mishandled-operand-size decode. It fired 1837 times but **all false positives** (the 0x66 was the
NEXT instruction's prefix; the current opcode was `8c`/`90`/`31`...). The decisive filter — a LEADING
`ibuf[0]==0x66` with `d_w==2` — matched **ZERO** times. So the decode width is **correct** (32-bit
ops get `d_w=4`); the bug is NOT a decode-width mistake. If the §23e truncation is real, it is in the
execution/value path (a 32-bit op with correct d_w=4 producing high16=0, i.e. a wrong loaded/stored/
computed value), not the prefix/width decode.

Honest caveat on §23e: qemu's `-d cpu` showed BOTH high-set (`edx=0x00800002,ebx=0x000e3772`) AND
high-0 (`edx=2,ebx=0x130e`) versions of these regs at the patch routine (different per-op iterations).
The RTL's high-0 values may match qemu's high-0 ITERATION rather than prove a truncation — i.e. the
divergence could be a different OP being selected, not a width truncation. The matching `0xe`
(ebx-high vs rel16 +0xe) is suggestive but not conclusive without confirming the two traces are at the
same operation. Re-verifying needs the qemu differential, which the environment is now killing
(qemu emulation runs get SIGTERM'd). So: decode ruled out; exec-vs-op-selection unresolved; final
pinpoint blocked. Method to resume: when qemu runs, single-step-align the patch op (match eax+the full
GPR set) before trusting the ebx/edx delta, then localize the producing instruction.

## 23h. CORRECTION: §23e truncation REFUTED — no register truncation

Cross-checking my OWN RTL data resolves the §23g caveat against the truncation hypothesis. At the
ACTUAL patch store (`cs=0x87:0x334`, the instruction that writes 0x26dfe82d to 0x29d30) the RTL regs
are `eax=0x101, edx=0x008000b7, ebx=0x000e0021` — the **high bytes 0x80 (edx) and 0x0e (ebx) are SET**,
matching qemu (`edx=0x00800002, ebx=0x000e3772`, high 0x80/0x0e). So the RTL does NOT truncate edx/ebx;
§23e compared a MISALIGNED point (RTL cs=0x18:0x2b6d, where edx=2 transiently, vs qemu's later EIP).
**The 32-bit-truncation root cause (§23e) is wrong** — retract it.

What remains CONFIRMED: the crash is the near-CALL going to the bare helper 0x5954 (rel16 0x26df)
instead of the PUSH-CS thunk 0x5946 (rel16 0x26d1) — a real +0xe in the SMC-patched call (verified
from qemu's `-d in_asm` showing `e8 d1 26` at the same address). The patch value 0x26dfe82d is a
copied template (in no GPR at the store), so the wrong rel16 was baked in earlier. The +0xe = the
thunk length, so it's a **thunk-vs-helper (far-vs-near) selection or a template-relocation divergence**
in go32's PM code — NOT a register width bug. Pinpointing still needs an operation-aligned qemu
differential, which the environment now blocks entirely (qemu emulation runs are killed; only the
binary `--version` succeeds). HONEST state: root cause NOT identified; the prior "breakthrough" was a
misalignment artifact; the confirmed fact is the +0xe wrong call target, origin unrooted.

## 23i. PRECISE ROOT SYMPTOM: the patched SHIFT COUNT is wrong (45 vs 12)

Located the patch exactly (qemu-free, via a template-value tap): the dword `0x26dfe82d` is stored ONCE
by `cs=0x87:0x338` to lin **0x29d31**, and the real-mode stub at cs=0x26ac:0x3266 reads/runs it.
Decoding the stub (cs=0x26ac base 0x26ac0) resolves the off-by-one and the real divergence:
```
  cs=0x26ac:0x3266  c4 5e fc       LES BX,[BP-4]          ; far ptr ES:BX
            0x3269  26 8b 57 02    MOV DX,ES:[BX+2]       ; hi 16
            0x326d  26 8b 07       MOV AX,ES:[BX]         ; lo 16  -> DX:AX = 32-bit value
            0x3270  b1 2d          MOV CL,0x2d  (=45)     ; <-- RTL.  qemu = b1 0c (CL=12)
            0x3272  e8 df 26       CALL 0x5954 (helper)   ; <-- RTL.  qemu = e8 d1 26 (CALL 0x5946 thunk)
```
So go32 patches `MOV CL,<count>; CALL <shift-helper>` to shift a 32-bit DX:AX by CL. The **shift count
diverges: 45 (RTL) vs 12 (qemu)**, and the count selects which helper entry the call targets (so the
+0xe rel16 is a CONSEQUENCE of the wrong count, not an independent bug). The patch dword differs in two
bytes: byte0 `0x2d` vs `0x0c` (the count) and byte2 `0xdf` vs `0xd1` (the rel16). 45>32 shifts the
value to garbage; the wrong helper skips PUSH CS -> stale far-RETF CS -> #UD.

So the ROOT is go32's computation of this **shift/normalize count** (cs=0x87 PM math: the decoded
fragment does `AND EAX,0x1ff; ADD ECX,EAX` with CL=ECX). 45 vs 12 -> off by 33. This is Quake/go32
fixed-point or float normalization; the count likely derives from an exponent or a bit-scan (BSR/BSF)
or an FPU result. NEXT (qemu-free, correct value known = 12): trace ECX/ESI feeding the count in the
cs=0x87 routine, and check whether the divergent input comes from an x87 FPU result or a bit-scan/
integer op — that op is the core bug. (Supersedes §23e/§23h: not a register truncation; it's a wrong
shift-count value.)

## 23j. What is CONFIRMED vs hypothesis (applying the §23h lesson)

CONFIRMED (from the RTL's own frozen-at-crash state + decoded bytes, no qemu alignment needed):
- The crashing near-CALL at cs=0x26ac:0x3272 targets **0x5954 (the bare shift helper)**, executed
  straight after, and 0x5954 is PAST the PUSH-CS adapter thunk at 0x5946 (`POP BX; PUSH CS; PUSH BX;
  CMP CL,0x10; JNB`). The shift helper ends in `cb` (far-RETF). So calling 0x5954 skips PUSH CS, the
  far-RETF pops a stale CS, and execution lands in cs=0x34 garbage -> #UD. **This crash MECHANISM is
  solid.** The call should target the thunk 0x5946 (which pushes CS for ANY count and then dispatches
  by CL) — so go32 patched the WRONG call target (0x5954 vs 0x5946, +0xe).
- The patch is one PM store (cs=0x87) of the dword to lin 0x29d31 = `MOV CL,imm` byte + the CALL.

HYPOTHESIS, NOT confirmed (same op-alignment caveat that made §23e wrong): that the RTL's CL=0x2d(45)
is "wrong vs 12". The stub is SMC-patched per shift operation, so the RTL's crashing-op count (45) and
the qemu count (12) I saw may be DIFFERENT operations. I must not assert the count is the root without
an operation-aligned comparison. What's certain is only the wrong CALL TARGET (thunk vs bare helper).

Net: the crash mechanism is fully understood (skip-the-PUSH-CS-thunk -> stale far-RETF CS). The ROOT —
why go32's SMC patch selects 0x5954 instead of 0x5946 — is NOT established; it needs an
operation-aligned qemu differential, which the environment currently blocks (qemu emulation runs are
killed). I am explicitly NOT claiming the shift-count (§23i) is confirmed as the cause.

## 23k. The SMC patch is `ADD [stub], EBX` — and EBX is the whole delta

Decoded the patch store at cs=0x87:0x338 (cs=0x87 base 0x228f0 -> lin 0x22c28):
```
  cs=0x87:0x334  8e 1e 26 06       MOV DS,[0x0626]
  cs=0x87:0x338  66 64 01 58 20    ADD dword [fs:bx+si+0x20], EBX   ; [stub@0x29d31] += EBX
```
So go32 PATCHES the stub call by ADDING EBX to it (not a MOV). From the captured regs EBX = **0x000e0021**.
And `RTL_dword - correct_dword = 0x26dfe82d - 0x26d1e80c = 0x000e0021 = EBX`. So EBX adds `0x21` to the
count byte (0x0c->0x2d) and `0x0e` to the rel16 byte (0xd1->0xdf, thunk->helper). **The entire
divergence is the single value EBX=0x000e0021 added by this one ADD.** The fix target is now: why is
EBX 0x000e0021 here when the result should be 0x26d1e80c (i.e. EBX should be 0x00000000, a no-op add,
if the stub template already holds the correct call).

CAVEAT (per §23h): I have NOT proven via an aligned reference that the qemu EBX is 0 / template is the
same — inferred from the dword arithmetic assuming the pre-ADD template matches. But this is now a
SINGLE register at a SINGLE identified instruction (`add [fs:bx+si+0x20],ebx` @cs=0x87:0x338), with the
needed value known (the add should net 0x26d1e80c). NEXT (qemu-free): trace EBX into cs=0x87:0x338 —
its 0x000e0021 — back to its producing op; high word 0x000e + low 0x0021 look like two packed fields
(a relocation/fixup delta) that should be 0 for this intra-segment call. That producing op is the
core-bug candidate.

## 23l. Found+fixed a REAL bug (16-bit PUSHAW/POPAW) — but it is NOT the Quake root

Traced EBX=0x000e0021 (the SMC-patch delta) to a write tap; the writer looked like POPA's hardcoded
`gpr_we[R_EBX]=mem_rdata` (S_USEQ). Inspecting the PUSHA/POPA path found a genuine ISA bug: the bus
driver (core_bus_driver.svh) and writeback (core_gpr_wb.svh) HARDCODE 32-bit (4-byte spacing,
mem_wstrb=1111, full-width register writes, ESP+=32) and ignore q_w. So the 16-bit forms PUSHAW/POPAW
(q_w=2, used in CS16/D=0 code) were mis-executed as 32-bit — corrupting each register's high 16 and
mis-stepping ESP. opgen/verify only exercise PM32 (D=1 = the 32-bit form), so it was uncaught. Fixed
(commit 78cd911): parameterize on q_w (strb_of(q_w), q_w-spaced addresses, reg_merge to preserve high
halves on POPAW, ESP +/- 8*q_w). The 32-bit path is byte-identical; **verify 98/98 GREEN, FreeDOS
still boots, verify-sys system-diff EQUIVALENT** (the 5d hardware-task-switch failure is pre-existing,
unrelated). This is a real correctness fix worth keeping.

HOWEVER, an instrumented post-fix run proves it does **NOT** fix Quake: identical 9,643,312-insn stop,
**EBX@cs0x87:0x338 still = 0x000e0021**, crash (cs=0x34) still reached. And the post-fix detector shows
**POPAW EBX-writes = 0** — so the EBX=0x000e0021 feeding the bad SMC patch does NOT come from the POPAW
path. The "POPAW writes EBX" attribution was WRONG — the q_w=2 capture and the post-fix behavior
conflict, i.e. the actual EBX=0x000e0021 producer is a 32-bit-unaffected path I have not yet isolated.
This is the SAME recurring trap (mistaking a propagating value for its origin) that the truncation
theory (§23e->§23h) hit; without an operation-aligned qemu reference (env-blocked) I keep mis-rooting
the value. NET: a real bug fixed + committed; Quake root still NOT found; crash unchanged.

## 23m. EBX=0x000e0021 is a PRESERVED value, not a fresh corruption — the wall, restated

Clean-packed precise capture of the EBX<-0x000e0021 writers (frozen at crash): dominant writer is
cs=0x87:0x2b73 (and a few cs=0x2b/cs=0x87:0x480), all w=2 (16-bit), value source NEITHER alu_out
(=0xd0) NOR mem_rdata (=0). Decisive: for a 16-bit write `reg_merge(old_EBX, X, w=2) = {old_EBX[31:16],
X[15:0]}`, and the result 0x000e0021 means old_EBX[31:16] was ALREADY 0x000e — so this write PRESERVES
the high half; it does not create it. The high 0x000e originates from some earlier 32-bit (w=4) EBX
write and is then carried through many legitimate 16-bit ops. State flags (S_TSW_*/S_INT_*/S_IRET/
S_LTR/S_USEQ) all read OTHER, so it is NOT a task-switch/interrupt/POPA writer either (the task-switch
theory is also out; the verify-sys 5d failure is the parallel session's separate WIP).

THE WALL (restated honestly): every value I trace is correctly PROPAGATED by the core; the divergence
is an upstream value (EBX high = 0x000e) whose CORRECTNESS I cannot verify RTL-only — I need an
operation-aligned qemu reference to know whether 0x000e is right or wrong, and the environment blocks
qemu's emulation runs. This is why successive root hypotheses (truncation §23e, EBX-corruption,
POPAW §23l) each tested false: they were propagating values mistaken for origins. Real result this
session: a genuine 16-bit PUSHAW/POPAW bug found+fixed+verified (78cd911); Quake root NOT found;
crash unchanged. Resolving Goal 2/3 fundamentally requires the aligned qemu differential (or the
parallel session's task-switch/other work), not more single-context RTL tracing.

## 23n. Task switch round-trips EBX correctly; EBX high=0x000e is likely a LEGIT pointer

Two RTL-verified negatives this cycle:
1. The EBX origin (high->0x000e) is a far JMP to selector 0x60 = a HARDWARE TASK SWITCH. Read the impl
   (core_tsw.svh + tsw_save_off/tsw_read_off in ventium_sys_pkg.sv): SAVE writes EBX->TSS+0x34 (beat 5),
   READ loads EBX<-TSS+0x34 (beat 6), S_TSW_BUSY reloads all GPRs. **Offsets consistent -> the switch
   round-trips EBX correctly.** So 0x000e0021 is RESTORED, not corrupted by the task switch. (The
   verify-sys 5d failure is the CALL/task-gate path, not this JMP path — separate WIP.)
2. Captured the FIRST EBX[31:16]->0x000e transitions from run start: it is a RECURRING high across many
   distinct instructions (0x000e9720, 0x000e0010, 0x000ef000, 0x000e0021), loaded from memory (e.g.
   `8b 1b` MOV EBX,[EBX] @cs=0x08:0x4c54). EBX is very likely a LEGITIMATE pointer into the 0x000Exxxx
   region — so the "EBX high should be 0x0000" derivation (§23m-ish) is itself suspect.

Re-framing: if EBX=0x000e0021 is a legit pointer, the bug is more likely the `add [fs:bx+si+0x20],ebx`
TARGET ADDRESS (the RTL resolving fs:bx+si+0x20 to the call dword 0x29d31 when it should hit a data
slot), or the control flow reaching this add — NOT EBX. Resolving which needs the operation-aligned
qemu reference (fs_base/bx/si correctness), which the env blocks. NET this session: real PUSHAW/POPAW
fix committed; task-switch ruled out; EBX likely legit; the true divergence (address vs value) is
unresolvable single-context. The honest conclusion stands: Goal 2/3 need the aligned qemu differential.

## 23o. BREAKTHROUGH: qemu works as oracle; EBX is CORRECT; bug = stub OVER-relocation

qemu was NOT actually env-blocked — FOREGROUND `qemu-system-i386 -d cpu` produces a 1.5GB register
trace fine (earlier failures were background/quoting/disk, and the "signal 15" was my own `timeout`).
With the aligned oracle, the whole EBX line of investigation is OVERTURNED:
- qemu has the EXACT same EBX=000e0021 (546x), edx=00800002, etc. **EBX is CORRECT** — the high 0x000e
  is a legit 0x000Exxxx pointer. Every prior EBX/truncation/POPAW/task-switch theory was a wrong lead.
- qemu calls the PUSH-CS thunk 0x5946 **138,339x** and the bare helper 0x5954 **ZERO** times, and never
  reaches cs=0x34. So qemu's go32 real-mode-call stub @0x29d31 is ALWAYS valid (=0x26d1e80c -> 0x5946).
- The disk (md5-identical to the RTL's) holds the stub at off 0xd406e = `8b 07 b1 0c e8 d1 26 8b` =
  0x26d1e80c (the VALID, already-relocated form, CL=0x0c rel16=0x26d1).

THE BUG (qemu-confirmed): the patch is `add [fs:bx+si+0x20], ebx` @cs=0x87:0x338, fs:off resolves to
0x29d31 in BOTH (FS=0x8f base 0x228f0 via `PUSH DS; POP FS`). For the result to be the VALID 0x26d1e80c
(qemu), the stub BEFORE the add must be 0x26c3e7eb = 0x26d1e80c - EBX. So **qemu UN-relocates the stub
(subtract EBX) before re-relocating it with this add — net valid.** The RTL skips the un-relocation:
its stub stays 0x26d1e80c (the disk value), so the add OVER-relocates -> 0x26dfe82d -> CL=0x2d, CALL
0x5954 (skips PUSH CS) -> stale far-RETF CS -> cs=0x34 -> #UD at 9.643M.

NEXT (now tractable — qemu is the oracle): instruction-level differential of go32/CWSDPMI's real-mode-
call setup (cs=0x87 ~0x320-0x338 + the INT 0x31 handler) to find the missed `sub [stub],ebx` un-
relocation (or the control-flow / segment condition that skips it). That op (or its skip) is the real
core bug. This supersedes ALL earlier root hypotheses; EBX/PUSHAW/task-switch are NOT the cause.

## 23p. Concrete oracle-confirmed lead: RTL DS base = 0x10000000 (qemu: 0x46010)

Decoded the real-mode-call setup at cs=0x87 (verified bases via qemu: cs/ds/ss/es=0x228f0):
```
  0x32f INT 0x31              ; DPMI simulate-real-mode-call (CWSDPMI handler)
  0x331 PUSH DS              ; DS=0x8f (base 0x228f0)
  0x332 POP FS               ; FS := DS = 0x8f  (so the add below uses the OLD ds via FS)
  0x334 MOV DS,[0x626]       ; DS reloaded
  0x338 ADD [fs:bx+si+0x20],EBX  ; fs:0x7441 -> 0x29d31, the stub
```
RTL tap at the add: **DS base = 0x10000000** (256MB, beyond the 64MB of RAM). qemu in cs=0x87 only ever
has DS sel 0xb7/base 0x46010 or sel 0x8f/base 0x228f0 — **NEVER 0x10000000**. So the RTL's
`MOV DS,[0x626]` (or the descriptor it loads) computes a WRONG base. This is a real, oracle-confirmed
segment-load/descriptor divergence (core domain). It does not directly mis-target the crashing add
(which uses FS, correct), but it shows the RTL diverges in this very routine's segment setup — and the
missing stub un-relocation (§23o) is almost certainly in the same INT 0x31 / segment-setup path.

TOOLING NOTE: qemu `-d cpu` (file) works as the oracle; the gdbstub (`-gdb tcp`) and `-d in_asm` do NOT
produce output in this env, so I can't yet watch qemu's stub memory writes directly. NEXT: (a) capture
the RTL's DS SELECTOR + [0x626] value + the GDT/LDT descriptor at 0x334 to localize the segment-load
bug (selector-read vs descriptor-base), and (b) trace the INT 0x31 (CWSDPMI) handler RTL-vs-qemu by EIP
to find the skipped stub un-relocation. Both are now tractable with the working oracle.

## 23q. Deepest divergence: OFF-BY-ONE LDT selector (RTL 0xaf vs qemu 0xb7) at [0x626]

Localized the DS=0x10000000 anomaly (§23p): RTL DS at the add = **sel 0x00af -> LDT[0x15], base
0x10000000**; qemu DS = **sel 0x00b7 -> LDT[0x16], base 0x46010**. The selector SOURCE `[0x626]`
(lin 0x22f16) holds **0xaf in the RTL vs 0xb7 in qemu** -> an **OFF-BY-ONE LDT descriptor selector**
(index 0x15 vs 0x16; both TI=1/LDT, RPL=3). RTL ldt_base=0x2d688, gdt_base=0x2ce00.

So the RTL's CWSDPMI DPMI-descriptor allocation is one LDT slot BEHIND qemu's (allocated one fewer, or
freed one extra, earlier) -> wrong selector in [0x626] -> wrong DS base (LDT[0x15]=0x10000000, a segment
beyond the 64MB RAM). This is the deepest, most concrete divergence found, and the registers MATCH at
cs=0x87:0x331 (so this is a MEMORY/descriptor-table divergence with matching regs, seeded earlier).

CAVEAT: the crashing add uses FS (base 0x228f0, correct in both), so DS=0xaf does not DIRECTLY mis-
target it. But the off-by-one LDT allocation is a strong candidate ROOT: it cascades to wrong DPMI
segment bases, and the stub un-relocation (§23o) may use such a (now-wrong) selector and miss. Whether
the two share this root needs qemu's MEMORY trace — and the env blocks every qemu memory path
(gdbstub TCP, monitor unix/stdio, in_asm, and any backgrounded qemu all fail; only FOREGROUND `-d cpu`
register tracing works). NEXT: trace the [0x626] selector write + the CWSDPMI ldt-alloc/free path to
find the one divergent allocation; or get qemu memory working to diff the LDT/[0x626] directly.

## 23r. The wall: the root is a MEMORY divergence; all qemu-memory paths are env-blocked

Two facts close off the remaining RTL-only avenues:
- The stub values (0x26d1e80c/0x26c3e7eb/0x26dfe82d) appear in ZERO qemu registers — so the stub
  relocation/un-relocation are DIRECT-memory ops (`add/sub [stub],ebx`), invisible to `-d cpu`.
- 0xaf is NOT simply "wrong": qemu uses EAX=0xaf 147x and EAX=0xb7 124x. So the off-by-one [0x626]
  selector is a selector CONFUSION (the RTL stored a valid-elsewhere selector where 0xb7 was needed),
  not a count error — confirming it's seeded by an earlier MEMORY/LDT-table state divergence.

Both the stub over-relocation and the [0x626] selector are MEMORY divergences with MATCHING registers
at the crash routine — so the seed is an earlier memory write, and tracing it needs qemu's MEMORY.
Every qemu-memory path fails in this env: gdbstub (`-gdb tcp`) won't bind, the monitor (unix socket,
and `-monitor stdio` with piped commands) produces nothing, `-d in_asm` is empty, and ANY backgrounded
qemu is killed. Only FOREGROUND `qemu -d cpu` (per-TB registers) works. A register-level differential
(the one avenue left with -d cpu) would only surface the divergence where it first hits a REGISTER —
i.e. at the crash routine (already known), not the memory seed. So the root is localized (CWSDPMI
descriptor/relocation state) but not reachable here without a qemu-memory channel. Honest state:
oracle-confirmed localization of a memory-state divergence; no fix; Goals 2/3 unmet; blocked on tooling.

## 23s. Allocation localized to CWSDPMI (CS=0x8e47); seed = an earlier LDT free-slot divergence

qemu's allocation of the DS selector 0xb7 happens inside CWSDPMI's descriptor code at CS=0x8e47
(base 0x8e470), EIP=0xcedd (EAX=00b7, ECX=d9, EDX=46). CWSDPMI's LDT-allocation scans the LDT for a
free descriptor; the RTL finds LDT[0x15] free (-> 0xaf) where qemu finds it OCCUPIED (-> 0xb7). So
some EARLIER DPMI descriptor allocation occupied LDT[0x15] in qemu but not the RTL -> the RTL is one
LDT slot behind. The seed is an earlier LDT-table-state divergence, which can only be traced with
qemu's MEMORY (the LDT contents over time) — env-blocked.

SESSION SUMMARY of the qemu-oracle breakthrough (supersedes ALL earlier root hypotheses):
- qemu (foreground `-d cpu`) is a valid aligned oracle; EBX/PUSHAW/task-switch theories were WRONG.
- Crash mechanism (solid): SMC-patched real-mode-call stub @0x29d31 ends up 0x26dfe82d (->CALL 0x5954,
  skips PUSH-CS thunk) -> stale far-RETF CS -> cs=0x34 -> #UD @9.643M. qemu: stub stays 0x26d1e80c
  (->0x5946 thunk) 138k x, never crashes.
- Root chain (memory divergences, regs match): off-by-one LDT alloc (RTL 0xaf vs qemu 0xb7) -> wrong
  DPMI segment bases (DS=0x10000000) -> the stub un-relocation in CWSDPMI's real-mode-call setup
  misses -> stub over-relocated -> crash. All seeded by an earlier LDT-state divergence.
- BLOCKER: every qemu-MEMORY channel fails here (gdbstub/monitor/in_asm/-trace/background qemu);
  only foreground `-d cpu` (regs, per-TB) works, and the stub/LDT ops are direct-memory (invisible
  to it). So the bug is precisely LOCALIZED (CWSDPMI LDT allocation) but the seed is not reachable
  without a qemu-memory diff. No safe speculative fix (would risk the green verify-sys baseline).

## 23t. Descriptors MATCH (not a core descriptor bug); it's the selector VALUE in [0x626]

Checked qemu's base for selector 0xaf: it is 0x10000000 (762,937x) — IDENTICAL to the RTL. So the LDT
descriptor contents match between RTL and qemu (LDT[0x15]=base 0x10000000 in both); this is NOT a core
descriptor-read/write bug. 0xaf (base 0x10000000) is the DPMI CLIENT's heavily-used data/stack segment;
0xb7 (base 0x46010) is the real-mode-call transfer BUFFER. So at the real-mode-call setup, go32 stores
the BUFFER selector 0xb7 into [0x626] (qemu) but the RTL has the CLIENT selector 0xaf there. The bug is
which selector VALUE lands in [0x626] — a memory-value divergence in go32/CWSDPMI's selector pick,
seeded earlier (a wrong value the core computed/loaded, or a wrong structure field), NOT a wrong
descriptor.

This is the cleanest statement of the wall: descriptors/registers MATCH; the divergence is a specific
memory VALUE ([0x626] selector; the stub un-relocation; the LDT free-slot the alloc returns), and
pinning which earlier write produced the wrong value requires qemu's MEMORY trace, which is
exhaustively env-blocked (gdbstub/monitor[unix,stdio,yes-stream]/in_asm/-trace/background qemu all
fail; only foreground `-d cpu` regs work, and these ops are direct-memory/invisible). No fixable core
descriptor bug; no safe speculative fix. Goal-2 root = a memory-value seed reachable only with a
qemu-memory channel.

## 23u. PINNED: the bug is the DPMI Allocate-LDT-Descriptors call returning an OCCUPIED slot

Traced the [0x626] selector to its exact producer. The real-mode-call setup at cs=0x87:0x250 decodes:
```
  0x250  89 06 24 06   MOV [0x624],AX     ; store prior selector (0xa7)
  0x254  31 c0         XOR AX,AX          ; AX=0
  0x256  cd 31         INT 0x31           ; DPMI fn 0000 = Allocate LDT Descriptors (CX descriptors)
  0x258  0f 82 ..      JC error
  0x25c  89 06 26 06   MOV [0x626],AX     ; store the ALLOCATED selector  <-- RTL 0xaf vs qemu 0xb7
```
So `[0x626]` = the result of DPMI Allocate-LDT-Descriptors. RTL returns **0xaf** (LDT[0x15]); qemu returns
**0xb7** (LDT[0x16]). And qemu's 0xaf descriptor is PRESENT (flags 0x..f300 = the client's data segment,
base 0x10000000) — so the RTL's CWSDPMI allocator handed out an **already-occupied** descriptor.

ROOT (as deep as registers reach): CWSDPMI's free-descriptor scan/free-list returns LDT[0x15] as free in
the RTL where qemu has it occupied -> an EARLIER allocation (the client data segment, which lands at
LDT[0x15] in qemu) used a different slot in the RTL, OR an extra free. The allocation RESULTS are register
data (AX), so the seed IS findable by diffing the allocation-result SEQUENCE RTL-vs-qemu — the one
remaining tractable avenue (not memory-blocked). Obstacle: the general allocator-return PC isn't cleanly
isolated yet (cs=0x8e47:0xcedd is only one specific exit, 6x), so a clean per-allocation AX diff needs the
CWSDPMI return point identified first. NET: bug pinned to one DPMI call; the seed is the first divergent
LDT alloc/free, reachable via a register-sequence diff (tractable) or qemu memory (blocked).

## 23v. The failure is ITERATION-SPECIFIC: a transient CWSDPMI free-list corruption

Selector usage (qemu): 0xaf (LDT 0x15) used 762,893x = the client DATA segment; 0xb7 (the real-mode
buffer) only 1,385x (alloc'd + freed PER real-mode call). The RTL boots FreeDOS + runs Quake to 9.64M,
so the buffer-alloc (INT 0x31 fn0000 @cs=0x87:0x256) SUCCEEDS many times before the crash. So the
failure is ITERATION-SPECIFIC: only at the crash iteration does the RTL's CWSDPMI free-scan return the
OCCUPIED 0xaf (client data, present) as if free. CWSDPMI's free-scan looks for a zero/not-present LDT
slot; at the crash iteration the RTL's LDT[0x15] is seen free but is actually the present client data ->
a transient free-list/descriptor desync right before the crash (a wrong free, or a scan reading stale
state). The buffer is alloc'd/freed every call, so this is a per-call alloc/free bookkeeping divergence
that goes wrong on one specific iteration.

This is the deepest reachable point: bug = one DPMI call returning an occupied slot on one iteration;
root = a transient CWSDPMI LDT free-list/descriptor desync, which requires the LDT + CWSDPMI free-list
MEMORY over time to pin — env-blocked (no qemu memory channel). A register-result diff would show the
alloc returning 0xaf vs 0xb7 (the known symptom) but not the free-list memory cause. No fixable core bug
isolated (descriptors + registers match; the divergence is CWSDPMI's internal memory state). No safe
speculative fix. FINAL localization for this environment.

## 23w. RTL-side LDT[0x15] descriptor trace: CWSDPMI (cs=26ac) alloc/frees the buffer slot

NEW RTL-side capability realized: I can dump the RTL's OWN memory + descriptors (no qemu memory needed
for the RTL side; qemu regs are the oracle). Traced writes to the LDT[0x15] descriptor (lin 0x2d730 =
ldt_base 0x2d688 + 0x15*8): it is set (limit 0xffff @cs=26ac:19e8, flags @1a11) and zeroed/freed
(@cs=26ac:00cd writes all 8 bytes =0; @cs=26ac:52df word-zeros) REPEATEDLY by CWSDPMI code at cs=26ac.
So CWSDPMI manages LDT[0x15] as the real-mode-call buffer descriptor in the RTL, where qemu uses
LDT[0x16] (0xb7). The buffer descriptor's base = 0x10000000 (HIGH memory, the client region) in the RTL
vs 0x46010 (LOW/conventional) in qemu — and real-mode code CANNOT address high memory, so the call
fails -> stub mishandling -> #UD.

So the bug = CWSDPMI's DPMI allocators (LDT + memory) hand the real-mode-call buffer a wrong (high-
memory / occupied-client) resource. The descriptor-management PCs are now known (cs=26ac:19e8/1a11/
00cd/52df = CWSDPMI alloc/free/set). The remaining step is to diff the alloc/free RESULT sequence
RTL-vs-qemu to find the FIRST divergent alloc/free (register data = tractable). The base-set write
(LDT[0x15].base<-0x10000000) is set early (before the captured window); tracing it + the fn0501/fn0100
memory-alloc result that feeds it is the concrete next probe. NOTE: this is CWSDPMI/DPMI-host program
behavior driven by an earlier alloc-state divergence — descriptors+regs match the oracle, so still no
isolated fixable CORE bug; the divergence is in CWSDPMI's free-list state evolution.

## 23x. Crash trigger is a ONE-TIME DPMI op (~9.64M), not the per-call path

The buffer-alloc routine at cs=0x87:0x256 (INT 0x31 fn0000) runs EXACTLY ONCE in the whole run (AX
captured 1x = 0xaf), right before the crash. So the crash is triggered by a SPECIFIC one-time Quake
DPMI operation near 9.64M (likely a graphics/VESA setup or a one-shot real-mode call), NOT the general
per-real-mode-call path (which runs many times fine, cs=26ac). At that one op the RTL's CWSDPMI returns
the OCCUPIED 0xaf where qemu returns free 0xb7 -> the wrong (high-mem 0x10000000) DS -> stub mishandle
-> #UD.

So by 9.64M the RTL's CWSDPMI LDT free-state has DIVERGED from qemu's (accumulated over the run's many
per-call alloc/frees), and the one-time op at 9.64M is where it first bites. The seed is an earlier
alloc/free whose RESULT diverged; the alloc results are register data (AX) so a register/alloc-result
differential RTL-vs-qemu over the run is the path, but it is a LARGE effort (9.64M insns, per-TB-vs-
per-insn alignment) and the alloc points are at many PCs. Descriptors+regs match the oracle at every
checkpoint -> no isolated fixable CORE bug; the divergence is CWSDPMI free-list state evolution.

STATUS: Quake crash precisely localized (one-time DPMI op -> CWSDPMI alloc returns occupied/high-mem
buffer); root is an accumulated CWSDPMI free-list divergence reachable only by a large alloc-result
differential. No safe speculative fix (descriptors/regs match; risk to verify-sys 949/949). Goal 1
solid; Goals 2/3 unmet, at the practical limit of single-context register-oracle debugging.

## 23y. LDT DUMP: descriptors are CORRECT — bug is the selector VALUE, not the buffer base

Dumped the RTL's full LDT (64 descriptors at ldt_base 0x2d688) just before the 9.64M crash and decoded
every entry. Ground truth:
```
  slot 0x14  sel 0xa7  base 0x10000000  type=code  P=1   client CODE
  slot 0x15  sel 0xaf  base 0x10000000  type=data  P=1   client DATA (occupied)
  slot 0x16  sel 0xb7  base 0x00046010  type=data  P=1   real-mode BUFFER — LOW memory, present, CORRECT
```
This OVERTURNS the earlier "RTL buffer is at high memory 0x10000000" framing (§23w). The buffer (0xb7)
EXISTS at the correct low/conventional base 0x46010 — identical to qemu. The descriptors MATCH qemu.

So the ONLY divergence is [0x626] = 0xaf (the occupied client-DATA selector) where qemu has 0xb7 (the
buffer). The real-mode-call setup's INT 0x31 fn0000 returned an OCCUPIED slot (0xaf, present per its own
descriptor) instead of a free one / the just-freed buffer (0xb7). Both 0xaf and 0xb7 are present in the
LDT, so this is NOT a descriptor or memory-base bug and NOT a missing buffer — it is a CWSDPMI
free-LIST / allocator-state desync: the host's free bookkeeping says LDT[0x15] is free while its own
descriptor says present. Also the paired fn0501 memory alloc returns the client region (0x10000000), so
BOTH allocators hand back in-use client resources at this one op -> a broad CWSDPMI allocator-state
corruption, recent (the op runs once near the crash). Next: timing probe (when the op runs) + the last
write to LDT[0x15]'s access byte (was 0xaf wrongly FREED right before, or is the free-list desynced with
a still-present descriptor). Root is a CWSDPMI free-list memory corruption seeded by an earlier core
divergence; descriptors+regs match the oracle so still no isolated fixable CORE bug at this layer.

## 23z. TIMING: the wrong selector is set at 8.908M (DPMI-INIT burst), 735K before the crash

Timing probe results:
- crash-op cs=0x87:0x258 runs EXACTLY ONCE, first @retire=8,908,304, AX=0x00af (the wrong selector).
- LDT[0x15] access word written 21x, LAST @retire=8,910,557 by cs=26ac:1a11 (configured right around the op).
- Pre-op LDT dump at 8.90M (lin 0x2d688): ENTIRELY EMPTY (all 64 descriptors zero).
- 9.64M LDT dump: fully populated (slots 0x10-0x16). So the LDT is BUILT in a burst at ~8.9M.

Reframing: the wrong [0x626]=0xaf is stored at 8.908M — 735K instructions BEFORE the 9.643M crash — and
the LDT is EMPTY just before, so this is Quake's DPMI-client INITIALIZATION (the LDT build), not a mid-run
buffer alloc or a late corruption. The op allocates 0xaf/LDT[0x15] where qemu allocates 0xb7/LDT[0x16].
Crucially the FINAL LDTs are IDENTICAL (both 0x15=client data base 0x10000000, 0x16=buffer base 0x46010,
both present, §23y) — so this is an allocation-ORDER off-by-one in the init burst: in qemu 0x15 (client
data) is allocated BEFORE the op so the op gets 0x16 (buffer); in the RTL the op gets 0x15 (which later
collides with / becomes the client data), so [0x626] points at the client's high-mem flat segment that
real mode can't address -> the 9.64M #UD.

This is a MAJOR narrowing: the root is a control-flow / allocator-state divergence inside a BOUNDED
~10K-instruction DPMI-init window at 8.9M (not a 9.64M-wide corruption), and an order divergence points
to a fixable CORE control-flow bug (a branch/condition evaluated differently) rather than an unreachable
memory desync. Next: capture the LDT-build write SEQUENCE in the burst (which PC writes 0x15 vs 0x16, in
what order) to localize the diverging branch; then a bounded register differential over 8.90-8.91M.

## 23aa. LDT-build POPULATION order: slots built 0x10->0x16 in order; LDTs identical to qemu

Captured the non-zero LDT population writes in the DPMI-init burst (after a bulk zero of 0x10-0x1f by
cs=26ac:52df). Order + content:
```
  0x10-0x13  base 0x228f0/0x227f0/0x22730  present   cs=26ac:0272/027f/0285/0299  (go32 segs)
  0x14       base 0x10000000  access 0xfb (code)     cs=26ac:1999/1a33/1a68/19e8   (client CODE)
  0x15       base 0x10000000  access 0xf3 (data)     cs=26ac:1999/1a33/1a68/19e8   (client DATA)
  0x16       base 0x00046010  access 0xf2 (data)     cs=26ac:17dd/1c10/1c1e        (real-mode BUFFER)
```
Slots are populated strictly in order 0x10->0x16. qemu's segment usage shows the SAME 7 LDT selectors
(0x87,0x8f,0x97,0x9f,0xa7,0xaf,0xb7 = slots 0x10-0x16) -> the LDTs are IDENTICAL. The ONLY divergence
is which selector the op (cs=0x87:0x256 fn0000) returns + stores at [0x626]: RTL 0xaf/0x15 (client DATA)
vs qemu 0xb7/0x16 (BUFFER). So the op-call is positioned ONE allocation earlier in the RTL's go32 init
call-sequence than in qemu's: an allocation call-ORDER / count divergence inside go32 (cs=0x87) during
DPMI init, NOT a descriptor, base, or allocator-table bug (the final tables match exactly).

ROOT (bounded, fixable target): a control-flow divergence in go32's DPMI init (cs=0x87) at ~8.908M makes
its fn0000 call-sequence off by one, so the buffer-selector store at [0x626] gets the client-DATA selector
instead. NEXT: a cs=0x87 PC-sequence differential RTL-vs-qemu across the init window (qemu's init op is
near oracle line ~2.70M) to find the first divergent branch -> the core instruction whose result/flag
differs. This is now a small, bounded compare, not a 9.64M-wide search.

## 23ab. CRITICAL CORRECTION: [0x626]=0xaf is IDENTICAL in qemu — the LDT/DPMI theory is DISPROVEN

Directly verified qemu's op in the oracle: CS=0x0087 EIP=0x0258 occurs EXACTLY ONCE with AX=0x00af
(EAX=000100af). So qemu stores 0xaf at [0x626] too — the SAME as the RTL. The "[0x626] = RTL 0xaf vs
qemu 0xb7" divergence that drove ~10 cycles (LDT off-by-one, DPMI allocator desync, free-list
corruption, alloc-ORDER, etc.) DOES NOT EXIST. The qemu "0xb7" was never actually observed at the op;
it was an unverified assumption that propagated. qemu's full state at the op: DS=0x8f (base 0x228f0),
EBX=000e0006, ESI=0x786, EDI=0x34, EBP=0x91e, ESP=0x770, EFL=0x3246. The LDTs, [0x626], and the op AX
all MATCH the RTL. NONE of the DPMI/LDT allocation is the bug.

The REAL divergence is CONTROL FLOW AFTER the op. qemu's post-op cs=0x87 path is
0x25c,0x26d,0x271,0x292,0x2a5,0x2b2,0x2c3,0x2cd,0x2da,0x2e2,0x2f5,0x33e,0x46c,0x477,0x479,0x360,0x47d,
0x48d,0x37d,...,0x3d8(loop). qemu hits 0x33e and NEVER 0x334; the RTL reaches 0x334 (MOV DS,[0x626] ->
DS=0xaf base 0x10000000, the path into the stub over-relocation). So both store the same [0x626]=0xaf,
then the RTL's control flow diverges to 0x334 where qemu goes 0x33e/0x360/... This re-centres on the
ORIGINAL finding (778760a): the go32 real-mode stub OVER-relocation (patched near-CALL -> 0x5954 helper
instead of 0x5946 PUSH-CS thunk). NEXT: capture the RTL's post-op cs=0x87 path, diff vs qemu's above,
find the FIRST divergent PC -> the branch whose condition/flag the core computes differently = the
fixable core bug. (The DPMI/LDT cycles were not wasted: they PROVED the descriptor/allocator state is
correct, eliminating a whole class of hypotheses.)

## 23ac. Post-op path MATCHES qemu -> divergence is near the 9.64M crash (stub generation), not the op

Captured the RTL's cs=0x87 path for 256 PCs from the op (0x258) onward and diffed vs qemu's TB-start
sequence. qemu's TB entries (025c,026d,0271,0292,02a5,02b2,02c3,02cd,02da,02e2,02f5,033e,046c,0477,0479,
0360,047d,048d,037d,0380,03a7,03b2,03d8) are ALL present in the RTL path (the RTL just lists every PC;
qemu lists only TB entries). So the post-op control flow MATCHES qemu, and the RTL does NOT hit 0x334
here -- it hits 0x33e like qemu and then LOOPS at 0x3d8 (and 0x477). So the op + its aftermath are
correct; the earlier "RTL reaches 0x334" was from a later point and is not a near-op divergence.

CONCLUSION: the divergence is NOT at 8.908M (the op) -- it is between ~8.91M and the 9.643M crash, inside
the real-mode-call STUB GENERATION. This fully re-centres on the ORIGINAL finding: the go32 real-mode
shift stub at lin 0x29d31 is "MOV CL,<n>; CALL <rel16>" = valid b1 0c e8 d1 26 (CL=0x0c -> 0x5946 PUSH-CS
thunk) but RTL b1 2d e8 df 26 (CL=0x2d -> 0x5954 bare helper). BOTH the shift count (CL 0x0c vs 0x2d) and
the call target (0x26d1 vs 0x26df) are wrong. NEXT: capture the writes that lay down those stub bytes
near the crash (who/what computes CL=0x2d and rel16=0x26df) -> the diverging core op. This is the true,
bounded target; the op/[0x626]/LDT was a long detour now closed off (all verified == qemu).

## 24. Bottom line (current, supersedes earlier)
- **Goal 1 — FreeDOS boot: DONE + validated** (verify 98/98 + verify-sys 949/949). Core fixes
  committed: `3925df5` (PM LSS/LFS/LGS), `6a6fa62` (S_LOAD2 paging cur_lin / null-SS #GP), `af05d38`
  (POP FS/GS), `17a630a`+`4b9225d` (nested ENTER + its paging), `8b5e7ce` (SHLD/SHRD mem), `a5e354f`
  (BT/BTS/BTR/BTC mem). Opcode roadmap: real gaps implemented; the remaining opgen "findings" are
  cov-env (POP-seg, §19) or non-crash-relevant.
- **Reference established (§20): qemu-system renders Quake on this exact disk** (640x400 VESA). So
  the RTL failure is a REAL, FIXABLE core bug, not a disk/setup problem.
- **Goal-2 root, narrowed to one wrong constant (§21-22):** the go32 real-mode call works by a
  near-CALL to a far-RETF shift helper via a PUSH-CS thunk (qemu confirms this is correct). On the
  crashing iteration the RTL's SMC-patched near-CALL targets **0x5954** (rel16 0x26df) instead of the
  thunk **0x5946** (rel16 0x26d1) — **+0xe, exactly the thunk length** — so the PUSH CS is skipped and
  the far-RETF pops the stale saved DI (0x34) as CS -> cs=0x34 -> #UD. RULED OUT: opcode gaps (opgen
  0 NEW-FAIL), timer, VESA-via-int10, SP-drift, code corruption, the near/far mechanism, DI value.
- **Goals 2/3: NOT met.** Remaining: (a) root the +0xe — find where go32's PM SMC-patch computation
  selects the near-entry 0x5954 instead of the far-thunk 0x5946 (a wrong far-vs-near selection /
  relocation in go32's PM code at cs=0x87:0x334), via a deeper PM trace or a memory-map-matched
  code-aligned qemu diff; (b) fix that core divergence; (c) extend ven_vga_fb to capture VESA so the
  rendered frames are visible. The bug is pinned to a single +0xe with a known oracle value (0x26d1);
  the fix path is concrete but a focused multi-step effort.
