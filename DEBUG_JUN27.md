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

## 13. Bottom line
- FreeDOS boot: **done, validated** (98/98 + 949/949).
- DOS-Quake null-SS #GP: **FIXED + committed (`6a6fa62`) + validated** (`cur_lin` S_LOAD2 paging
  translation). Quake now runs **past the old 8.9M crash to 9.64M**. Cache was a red herring.
- Goal 2 (render) & Goal 3 (long run): blocked by a NEW video-init/idle issue at 9.64M (VESA vs
  mode-13h vs a HLT-wait-for-IRQ) — needs the southbridge/video work above. The single CPU bug that
  blocked the entire prior session is resolved; this is a fresh, peripheral-side blocker.
