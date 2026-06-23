# DEBUG_JUN22 — F4A DOS‑Quake `eip=0x24e` fault: full investigation log

**Status (2026‑06‑23, transferred env): the entire DOS‑Quake CPU/DPMI ISA blocker chain is
RESOLVED — both the "Division by Zero eip=0x24e" AND the downstream spurious `#GP`
(eip=0x7a0, err=0x2593) are gone. The boot runs correctly through CWSDPMI/go32/DPMI into
deep Quake code (no S_HALT/#GP/d_unknown past the old fault). An actual rendered frame is
now gated on RUNTIME (Quake's ~1B‑insn Alpha_Init precompute — impractical in sim, feasible
on‑board at 40 MHz), not CPU bugs. `make verify` 98/98 GREEN; `make verify-sys` all sys
gates SYS‑GOLDEN‑OK. Next = commit the fix chain + respin + board (task #103).**

> **Full fix chain (6 links, all uncommitted — preserve):** 1. 16‑bit ENTER + SMSW.
> 2. PM pop‑sreg base (`sel<<4`→S_SEGLD walk). 3. PM far RETF (S_HALT→S_RETF→S_LJMP walk).
> 4. CPUID P6→P54C (`gen_trace.py` dropped `--cpu` → SoC model built from qemu default cpu).
> 5. POPF IOPL mask (CPL=3‑hardcoded → mode/CPL‑aware). 6. **16‑bit POPF high‑word leak**
> (`core_exec.svh:656` `if (q_w==3'd2) popf_mask &= 0xFFFF`) — the #GP root: a 16‑bit `popf`
> applied the 32‑bit mask to `mem_load_data[31:16]` (the next stack word), leaking a bit into
> EFLAGS.ID → stuck → CWSDPMI's CPUID‑detect tripped its exception reporter → the spurious
> `#GP`. Directed gates: `pseg`, `psocpmretf`, `ppopf` (+PHASE A2). All qemu‑`-cpu pentium`‑confirmed.

> **2026‑06‑23 — chain of CPU/DPMI ISA fixes that resolved "Division by Zero":**
> 1. **16‑bit ENTER + SMSW** (transferred, committed) — §2 below.
> 2. **PM pop‑sreg base** (`rtl/core/core_exec.svh`): `pop ds/es/ss` used the real‑mode
>    `sel<<4` base even in protected mode → CWSDPMI's `pop ds` (sel 0x33) got base 0x330
>    instead of the GDT[6] base 0x2b570, so the dispatcher's vector store and read‑back hit
>    *different pages* → read 0 → mislabeled "Division by Zero". Fix: gate on `seg_real`;
>    PM diverts pop‑sreg to the `S_SEGLD` descriptor walk (reusing `MOV Sreg,[mem]`).
>    qemu‑oracle‑confirmed. Directed test `verif/sys/tests/pseg`.
> 3. **PM far RETF** (`core_fetch_decode.svh` + `core_seg_ljmp.svh`): `0xCB` RETF in PM
>    fell through to `S_HALT` (the "PM RETF HALTs" gap, §3). CWSDPMI's dispatcher
>    far‑returns in PM → halted. Fix: route PM RETF → `S_RETF` → latch popped CS:EIP →
>    `S_LJMP` descriptor walk (mirrors PM far CALL). Directed gate `verif/sys/tests/psocpmretf`.
>
> Verified clean rebuild: **0× "Division by Zero", no `S_HALT`/`d_unknown`**; boot runs to
> retire 9,963,989, DPMI dispatch completes, Quake exits to DOS. **NEW BLOCKER:** the VGA
> console now shows `General Protection Fault at eip=7a0; flags=3212 ... error=2593` — a
> spurious `#GP` (vec 13), error code 0x2593 = a *selector* (the real‑mode CWSDPMI segment
> treated as a PM selector?). qemu runs the same image into deep Quake without it.
> *(Also separate/benign: `ven_ide: ABORT unsupported cmd=a1` = ATAPI IDENTIFY, Quake
> probing for a CD‑ROM.)*
>
> **Toolkit that cracked this layer (after 3 earlier methodology‑error diagnoses):**
> the DOS‑Quake run IS deterministic (`VEN_IRQ0_PERIOD=8000`, two runs byte‑identical);
> the refs **qemu‑system‑i386 8.2.2 oracle** builds with the **conda python**
> (`--python=/home/yukidama/miniconda3/bin/python3`; the script's `/usr/bin/python3` lacks
> `ensurepip`). Forward‑diff method: filter the timer‑IRQ interludes, align the
> non‑IRQ stream, the FIRST committed‑state divergence is the bug (a downstream symptom is
> not). Watch the ACTIVE memory port (the BFM under no‑`--l1-axi`, not the inert one).

**(historical) Status: 16‑bit real‑mode ISA gap chain COMPLETE. DOS now boots to go32/CWSDPMI
protected‑mode ring‑3. Live blocker has moved to a PM INT 0x31 / DPMI / paging
divergence (categorically different from the decode gaps). `make verify` GREEN 98/98.**

> **LATEST (end of session, agent `abf8`):** The 16‑bit chain (ENTER, SMSW, and the
> 16‑bit PM interrupt‑gate/IRETW path) is done and verified vs qemu‑system (`pintr16`,
> `pintr`, `pcpl`, `pv86` = 4/4 RTL‑SYS‑DIFF‑OK). With `VEN_IRQ0_PERIOD=8000` the boot
> reaches retire ~9.96M: FreeDOS banner, AUTOEXEC runs, go32/CWSDPMI enters PM (CPL=3,
> PG on), no `S_HALT`/`d_unknown`/`cpu_hung` anywhere. The go32 "Division by Zero" banner
> is reached via **DPMI exception reflection after an INT 0x31**, NOT a CPU divide
> (`DIVDE cnt=0`; the only PM gates in the whole boot are two INT 0x31 DPMI calls at
> `cs=0087 eip=0x24c cr0=80000019` (PE+PG); qemu runs the same image into deep Quake PM
> at `EIP=0x2f06e` without faulting). **Next target: the INT 0x31 / DPMI / paging path at
> go32 init (CWSDPMI at cs=0x87, paging on).**
>
> **Repro recipe:**
> ```
> make -C verif/tb l1axi_kv_dos_q
> VEN_NO_FRAME_EXIT=1 VEN_IRQ0_PERIOD=8000 VEN_PMGATE_LOG=1 \
>   ./verif/tb/obj_dir_l1axi_kvdosq/tb_ventium --system --dos \
>   --image sw/ps/kv260/assets/seabios.bin --disk sw/ps/kv260/assets/quake_ven.img \
>   --no-trace --max-insn 30000000 --max-cycles 1800000000 --quiesce 50000
> ```
> `VEN_PMGATE_LOG=1` (in `tb_main.cpp`, env‑gated/inert) logs PM `S_INT_GATE` deliveries.
>
> **The ~1.53M SeaBIOS wedge is NOT an RTL bug** — bisected to the new PIT‑driven IRQ0
> pump default (`tb_main.cpp` + `ven_pit.c` `ven_pit_set_emu_ns`) delivering an IRQ0
> during early SeaBIOS. `VEN_EMU_MIPS` tuning (100→3000) doesn't help; only the legacy
> fixed `VEN_IRQ0_PERIOD=8000` pump boots. The PIT WIP is preserved; its **default
> cadence needs fixing** (hold off IRQ0 until the guest programs counter0, or default to
> `VEN_IRQ0_PERIOD=8000` for `--dos`).

---

## 1. Symptom

DOS‑Quake on the KV260 (and, as later proven, in plain Verilator) prints to the VGA
text console:

```
0|Division by Zero at eip=24e; flags=3246
1|eax=00010000 ebx=00000006 ecx=00000001 edx=000007cf esi=00000786 edi=00000034
2|ebp=0000091e esp=00000770 cs=2b ds=8f es=8f fs=0 gs=0 ss=8f error=0000
3|C:\QUAKE>
```

It was originally believed to be a **board‑only instruction‑fetch corruption** (an
"A[2]‑drop", a marginal‑hold/silicon timing effect) that did not reproduce in
simulation. **That framing was wrong** (see §3, §4).

---

## 2. DEFINITIVE ROOT CAUSE

**The Ventium core does not decode the 16‑bit‑operand (real‑mode) forms of several
instructions used by go32 / CWSDPMI's startup. It raises `d_unknown → S_HALT` where
qemu executes the instruction and continues. The "Division by Zero" is a *mislabel*
— the CPU never raises vector 0; the core simply halts upstream, and `eip=0x24e` is the
go32 exception‑reporter's *client* EIP, which qemu passes through normally.**

### First (pinned) divergence — 16‑bit `ENTER`
| | |
|---|---|
| Instruction | `ENTER 0x000c, 0x00` — bytes `c8 0c 00 00` |
| Location | `CS:EIP = 0x2593:0x04da` (linear `0x25e0a`), **real mode** (CR0.PE=0) |
| When | **deterministic** at retire **8,610,841** (identical across 3 PIT‑timer configs) |
| Why | real mode default operand size = 16‑bit → `eff_opsize = pfx_opsize ^ def16 = 1`. The `C8` decode arm in `decode_stages.sv` accepted **only** `!eff_opsize` (the 32‑bit form); the 16‑bit form fell to `d_unknown → S_HALT`. |

**qemu cross‑validation (byte‑exact):** at linear `0x25e0a`, `qemu-system-i386 -d
in_asm,cpu` shows architectural state **identical** to Ventium (EAX=6, EBX=0x800,
ECX=0x80000001, EDX=0x0781abfd, EDI=6, ESP=0x6fc8, EIP=0x4da, CS=2593, CR0=0x10),
then decodes the **same** `c8 0c 00 00`, executes it, and runs **178M+ more
instructions** into the protected‑mode go32 client (CPL=3 CS32 = Quake). Ventium tracks
qemu *exactly* up to this instruction. Zero PM exceptions occur before the halt.

### It is a CHAIN, not one bug
After the ENTER fix, the boot advances `8,610,841 → 8,643,414` and halts again on the
**16‑bit `SMSW`** (`0f 01 e0` = `smsw ax`, then `and ax,1` — go32's "am I in PM?"
check) at `CS:EIP = 0x2593:0x2d33`. Expect a short chain of 16‑bit real‑mode ISA gaps
(candidates: SMSW, LMSW, LGDT/LIDT/SGDT/SIDT, SLDT/STR, MOV CRx, far JMP/CALL).

---

## 3. What works / what is proven correct

- **The CPU is correct through 8.6M instructions** of SeaBIOS POST + FreeDOS boot +
  go32 startup — byte‑exact vs qemu up to the 16‑bit ENTER.
- **`make verify` is GREEN (98 PASS / 0 FAIL)** with the ENTER fix in the tree
  (tx_fprem passes too).
- The interrupt subsystem is correct: across 3,624 maskable‑IRQ deliveries **IF=1 on
  every one** (zero while masked); the `intr_take` gate (`core.sv:1553`) requires
  `eflags[9]`; the 8259 model (`ven_pic.c`) honors IMR/ISR/EOI/ELCR. **No masking bug.**
- The L1/fetch datapath is structurally and timing clean (see §4 eliminations).

### Real fixes banked this session (uncommitted, in the working tree)
| Fix | Files | Status |
|---|---|---|
| **16‑bit `ENTER`** (root cause #1) | `decode_stages.sv` (C8 arm `d_w=eff_opsize?2:4`), `core_gpr_wb.svh` (SM_ENTER `reg_merge` to preserve EBP/ESP[31:16]) | done, `make verify` green, qemu‑validated |
| **16‑bit IDT gate frame** ("fix1") | `core_int_deliver.svh` (`int_gate_op16<=!gattr[3]`), `core_bus_driver.svh`, `core_gpr_wb.svh` | real latent bug; `pintr16` test passes; **not** the Quake trigger but correct |
| **PIT fidelity** | `ven_pit.c` (injectable emu‑ns clock), `ven_periph.h`, `tb_main.cpp` (PIT‑driven IRQ0 at the guest‑programmed rate), `ven_soc_app.c` (board PIT off DBG perf counters) | genuine fidelity win; `make verify` green; **not** the Quake trigger |
| **PM far RETF** (gap, not yet fixed) | `core_fetch_decode.svh` / `decode_stages.sv` note "PM RETF HALTs" | identified real gap; separate follow‑up |

---

## 4. Hypotheses tried and DISPROVEN (the elimination chain)

This took ~12 hypotheses. Each was disproven with reproducible evidence; the trail is
recorded so nobody re‑chases a dead end.

1. **Board‑only fetch corruption / "A[2]‑drop" (the starting premise).** DISPROVEN — the
   fault reproduces in plain Verilator (§ the methodology break, #8 below), and fetch
   address bit[2] is structurally clean in the routed netlist.

2. **Marginal HOLD on the uopcache `wbuf_slots → store_slots_b` BRAM write.** Chased
   through **5 FPGA builds** (`holdfix`, `FP_PS_ALL`, `+FST‑trap`, `+FP‑load‑trap`,
   `+FBLD‑trap`). DISPROVEN — the fault is **byte‑identical across all builds/placements**
   (a hold race varies with placement), and the fetch‑path hold floor (~+0.038 ns) is a
   **global clock‑skew limit** partly in **untouchable Xilinx SmartConnect IP**, unmovable
   by core‑logic reduction. The `VENSLOW` 496 kHz test (single‑clock design → no CDC)
   also ruled out setup. The whole hold campaign was a ghost.

3. **icache `ic_line_a/b` declone.** DISPROVEN — that data array is **synth‑pruned** under
   `VEN_UOPCACHE` (0 cells); fetch sources the uopcache + the FF‑based `ibuf[16]`.

4. **Fetch‑address bit[2] structural drop.** DISPROVEN — bit[2] is structurally clean in
   the routed netlist (no tie, swap, or mis‑wired RAM addr).

5. **uopcache `store_slots` read‑during‑write BRAM collision.** DISPROVEN — the board
   runs **functional mode** (`cycle_mode=0`), where the uopcache fast path is **bypassed**;
   injecting `'x` on every RDW collision left the sim **byte‑identical** (the slot data
   never reaches a fetched instruction).

6. **The live `ibuf`/decode fetch capture path.** DISPROVEN — timing‑clean (worst hold
   +0.667 ns, setup +11.5 ns), `ibuf` is FF‑based (no RAM collision), and S_FETCH fills
   all 16 bytes before S_DECODE (no fill/read race).

7. **L1AXI read‑data (`dc_line → rd_window_q`) capture.** DISPROVEN — the L1 read path is
   2‑state clean (word‑select, read‑during‑fill, beat order, source mux all verified), and
   the design is single‑clock so `VENSLOW` ruled out setup on it.

8. **★ THE METHODOLOGY BREAK ★** — the `#DE` **reproduces in plain 2‑state Verilator**
   once the sim is run to fault depth. Every prior "sim is clean" was a **too‑short‑run
   artifact**: the default `--max-cycles = 1<<24 = 16.77M` stopped *before* the fault
   (~180M cycles). It is **path‑independent** (byte‑identical with `--l1-axi`/`ven_l1d`
   serving reads OR the behavioral BFM serving them). ⇒ a **functional CPU bug**, not
   timing/fetch. *(Also: ven_l1d sims require `--l1-axi`; `--dos` alone leaves it inert.)*

9. **CPU miscompute → narrowed to a stack corruption in go32's INT‑21h AH=4Bh EXEC /
   DPMI dispatch.** Partially right (it is a CPU bug in that region) but the mechanism
   below was wrong.

10. **Stale `cs_d` across a real↔16‑bit‑PM transition IRET mis‑sizing the frame.**
    DISPROVEN — over retire [9.35M..9.48M] every IRET is real‑mode `S_RMIRET` (+6 bytes);
    **zero** PM IRETs, **zero** `mov cr0` PE‑toggles; `cs_d=0` throughout. The cs_d fix
    changed nothing **and** is architecturally wrong (x86/qemu don't reload CS.D on a bare
    `mov cr0`). Reverted.

11. **A 12‑byte (3‑dword) frame mis‑size storing RMCS.SP.** DISPROVEN — the qemu golden
    (gdb hardware watchpoint on the store) showed the stored SP **values match qemu**; the
    "12 low" was a **misaligned comparison** of two *different* reflection instances. The
    real divergence was a **reflection COUNT** (one extra reflection).

12. **Timer cadence (an extra timer‑tick reflection).** DISPROVEN — a correctly‑rated PIT
    was built and the Quake‑phase timer density swept **25000×**; the crash stayed **invariant**
    at retire ≈ 8.4537M ± 800. The earlier "changing `VEN_IRQ0_PERIOD` moves the crash"
    was just **boot‑length** variation; the crash is at a **fixed ~4.15M instructions into
    Quake's own stream**. ⇒ deterministic in Quake's code, not cadence.

13. **★ ROOT CAUSE ★** — the 16‑bit `ENTER` (and the chain of 16‑bit real‑mode ISA gaps).
    See §2. Pinned by trapping the actual fault path (zero PM exceptions before the
    divergence → the core *halts*, it doesn't fault) and byte‑exact qemu cross‑validation.

---

## 5. What does NOT yet work (open items)

- **The 16‑bit ISA‑gap chain is not fully cleared.** Next blocker: 16‑bit `SMSW`
  (`0f 01 e0`) at `0x2593:0x2d33`. Likely a few more (LMSW/LGDT/LIDT/etc.) before go32
  enters PM and reaches Quake.
- **The full DOS‑Quake boot does not yet render a frame** — gated on clearing the chain.
- **A separate, pre‑existing regression** wedges the *current* working tree's
  `l1axi_kv_dos_q` early (~1.53M, SeaBIOS i8042/A20), independent of ENTER — most likely
  from the uncommitted FP/uopcache WIP. The BFM also has early‑SeaBIOS run‑to‑run
  non‑determinism. Needs isolation so the full boot repros cleanly.
- **Directed tests for the 16‑bit forms must live in `verif/sys/`** (qemu‑system
  real‑mode, SS.B=0 — like `pintr16`/`t_leave16`), **not** the 32‑bit user gate. A
  `t_enter16` using a `0x66`‑prefixed ENTER in flat‑32 mode exercises the *wrong regime*
  (op16/stack32: qemu writes full EBP while the in‑tree `reg_merge` preserves EBP[31:16])
  and was correctly removed.
- **Board respin** is pending — only needed *after* the chain clears in sim. No board
  cycle is required to find or fix any of this.

---

## 6. Assets produced but NOT the fix (keep for future respins)

- **FP_PS_ALL** (remove the x87 FPU compute from PL, trap all x87 to PS): proven area
  win **92% → 63% LUT**, with a complete PS x87 emulator (SoftFloat extF80, host gate
  20/20, aarch64 cross‑build clean). Built to chase the (wrong) marginal‑hold hypothesis;
  kept as a real area‑relief asset for a future board fit. The cross‑build also fixed a
  SoftFloat FAST_INT64 vs platform mismatch.
- The on‑die diagnostic hooks (`+ven_iretdbg` plusarg in `core.sv`, `VEN_RETDUMP_*` in
  `dpi_retire.cpp`, `VEN_WATCH`, `VEN_NO_FRAME_EXIT`) — env/plusarg‑gated and inert by
  default; reusable.

---

## 7. Methodology lessons (so this is faster next time)

1. **Run the sim to the actual fault depth.** The single biggest time sink: the default
   `--max-cycles=1<<24` stopped before the ~180M‑cycle fault, making a sim‑reproducible
   bug look "board‑only" for a long time. Always raise `--max-insn/--max-cycles` and use
   `VEN_NO_FRAME_EXIT=1` to run past the frame‑exit.
2. **`ven_l1d` sims need `--l1-axi`** — `--dos` alone leaves the L1 inert (BFM serves
   reads), so "the sim is clean" can be testing the wrong path.
3. **Byte‑exact qemu cross‑validation is the deciding tool.** Use `qemu-system-i386 -d
   in_asm,cpu` (fast TB‑level logging), **not** gdbstub single‑step (too slow to reach
   ~9M). Align on a common anchor; the *first* committed‑state divergence is the bug — a
   downstream symptom (e.g. the RMCS.SP "lag") is not.
4. **"Board‑only + sim‑invisible" is a strong claim — verify it before building bitstreams.**
   A whole 5‑build FPGA campaign chased a timing ghost for a bug that was deterministic and
   sim‑reproducible all along.
5. **A go32/DOS "Division by Zero" is frequently a mislabel** — the runtime's generic
   exception reporter; the CPU may simply have halted on an unimplemented opcode upstream.
   Trap the *actual* fault/halt path, not the reported `eip`.

---

## 8. Repository housekeeping (done this session)

Debloated the repo **73G → 13G** by removing git‑ignored, regenerable build artifacts:
~110 stale `fpga/build` experiment bitstreams (kept `hpc40ft`, `ff3`), ~50 old Verilator
`obj_dir_*` (kept `obj_dir`, the in‑use `obj_dir_l1axi_kvdosq`), old `build/`
milestone/coverage/benchmark dirs (kept `verify`, `sys`, `golden-cache`), plus ~22G of
stale `/tmp` qemu/Ventium trace logs. All tracked source + the uncommitted RTL fix chain
were preserved.

---

## 9. Next steps

1. **Walk the 16‑bit real‑mode ISA‑gap chain** (SMSW next, then whatever halts next) —
   decode/execute each 16‑bit form, cross‑check vs qemu, until go32 enters PM and Quake
   renders. *(in progress)*
2. Add `verif/sys/` directed tests (real‑mode, SS.B=0) for each fixed instruction.
3. Isolate/fix the separate ~1.53M SeaBIOS regression from the uncommitted WIP so the full
   boot is deterministic.
4. Keep `make verify` GREEN throughout.
5. Once DOS‑Quake renders in sim: commit the fix chain as a milestone, respin the
   bitstream, deploy to 10.0.0.4, and confirm the frame on silicon.
