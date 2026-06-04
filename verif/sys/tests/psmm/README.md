# Ventium M2S.5 — SMM / RSM (PARTIAL-ORACLE stage)

System Management Mode: `SMI#` → save the CPU state to the SMRAM save-state map →
run the SMM handler in a special real-mode-like context → `RSM` (`0F AA`) restore
and resume. This directory is the **Phase-1 corpus + de-risk** for M2S.5. Per the
spec (`docs/m2s5-smm-spec.md`), the corpus phase **de-risks the SMI oracle first**
and scopes honestly — and the de-risk verdict here is **differential-golden
INFEASIBLE**, so this is a documented partial oracle: a real, working SMM
demonstrator that is **structurally self-checked** (no fabricated golden), with the
differential part deferred.

## TL;DR

| question | answer |
|---|---|
| Can a bare-metal program trigger `SMI#` deterministically under `qemu-system-i386`? | **YES, free-running**, via an APIC self-IPI with delivery-mode = SMI. **NO** via the port-`0xB2` APM path on a raw `-bios` image. |
| Does the gdbstub single-step into/out of SMM and expose the SMM context? | **NO.** `SMI#` is masked during single-step, and the gdbstub has no SMM awareness. |
| Does qemu use the P5 SMRAM save-map layout? | **NO** — it uses the P6/SDM-34.4 layout. |
| Verdict | **Differential golden INFEASIBLE.** Structural self-check + documented defer. |

## De-risk findings (the gating step), precisely

### 1. Triggering `SMI#`

* **Port `0xB2` (ACPI/APM SMI command): does NOT fire SMI.** On the `pc`
  (i440FX + PIIX3) machine, `out 0xB2` reaches the PIIX4 PM device's APM control,
  but the APMC→SMI gate is `if (d->config[0x5b] & (1 << 1))` in
  `hw/acpi/piix4.c:apm_ctrl_changed()`. That PCI config bit is programmed **only by
  firmware** (SeaBIOS). A raw `-bios` test image *replaces* SeaBIOS and never sets
  it, so the write is silently dropped. Empirically the SMM handler never runs
  (the `[0x2000]` sentinel stays `0`).
* **APIC self-IPI with delivery-mode = SMI: FIRES SMI free-running.** QEMU's local
  APIC honours `APIC_DM_SMI` → `cpu_interrupt(CPU(s->cpu), CPU_INTERRUPT_SMI)`
  (`hw/intc/apic.c:151`). Writing ICR-low `0x00040200` (dest-shorthand = self,
  delivery-mode = SMI) dispatches the SMI. Empirically the handler runs
  (`[0x2000] = 0x5A4D5A4D`) and `RSM` resumes the mainline.

### 2. The gdbstub single-step CANNOT observe SMM (the hard blocker)

The system-mode oracle (`gen_trace.py --system`) is built entirely on the
qemu-system-i386 GDB-stub **single-step** (`s`) path. That path **masks `SMI#`**:

* `gdbstub.c:73` sets `sstep_flags = SSTEP_ENABLE | SSTEP_NOIRQ | SSTEP_NOTIMER`.
* `accel/tcg/cpu-exec.c:cpu_handle_interrupt()`: when `singlestep_enabled &
  SSTEP_NOIRQ`, it does `interrupt_request &= ~CPU_INTERRUPT_SSTEP_MASK`.
* `include/exec/cpu-all.h`: `CPU_INTERRUPT_SSTEP_MASK` **includes**
  `CPU_INTERRUPT_TGT_EXT_2`, and `target/i386/cpu.h:1203`:
  `#define CPU_INTERRUPT_SMI CPU_INTERRUPT_TGT_EXT_2`.

So `SMI#` is **never delivered between gdb `s` steps**. Confirmed empirically:
single-stepping this exact image runs from reset all the way to the
isa-debug-exit and the SMM context (CS base = SMBASE, EIP `0x8000`) appears in
**zero** records; the SMM `[0x2000]` sentinel stays `0`. The SAME image, run
**free** (no gdb), fires SMI and the sentinel becomes `0x5A4D5A4D`.

Additionally `target/i386/gdbstub.c` has **no SMM awareness** — the `g`-packet
carries no SMM-active flag (it is HMP-only via `info registers … SMM=`, per
`docs/m2s0-system-spec.md` / M2S.0). Even if SMI were delivered, the stub would
not expose the SMM context register block.

### 3. The save-state map layout is P6, not P5

`target/i386/tcg/sysemu/smm_helper.c:do_smm_enter()` (32-bit branch) writes the
**P6 / SDM-34.4** save area: `sm_state = smbase + 0x8000`, with CR0 at
`sm_state + 0x7ffc` (= SMBASE+0xFFFC), EIP at `+0x7ff0`, EFLAGS at `+0x7ff4`, etc.
The **Pentium (P5)** layout this RTL stage targets is at **SMBASE+0xFE00** with a
different field order. So even a captured save area would not be byte-comparable to
a P5-faithful RTL. (Confirmed: post-SMI, `0x3FFFC = 0x60000011` (saved CR0),
`0x3FFF0 = 000f00d1` (saved EIP) — the P6 offsets — while `0x3FE00..` is untouched.)

## What is here

| path | what |
|---|---|
| `psmm.S` | bare-metal SMM/RSM demonstrator (real→protected; install handler @ SMBASE+0x8000; APIC self-IPI SMI; handler writes a sentinel + `RSM`; mainline resumes + proves state intact) |
| `psmm.ld` | linker script (flat 64 KiB `-bios` image; reset stub @ `0xFFF0`) |
| `Makefile` | `gcc -m32` build → `psmm.bin` (exactly 64 KiB) |
| `psmm-selfcheck.py` | the structural self-check: run free + QMP physical-memory readback |
| `manifest.json` | load/exit metadata + the full oracle-feasibility verdict |

There is intentionally **no `psmm.sys.vtrace.golden`** — see above.

## The structural self-check (the partial-oracle substitute)

`bash verif/sys/run-sys-golden.sh psmm` runs the M2S.5 branch:

1. builds `psmm.bin` and confirms it runs to the isa-debug-exit (status 133);
2. **(a)** generates a gdbstub single-step trace and asserts it shows the SMM
   context in **0** records — the honest, in-gate demonstration that the
   differential golden is infeasible (so none is fabricated);
3. **(b)** runs `psmm-selfcheck.py`: launches the image **free-running** (SMI
   fires) and proves the full SMM round-trip via QMP physical-memory readback:
   * `[0x2000] = 0x5A4D5A4D` — the SMM handler ran in the SMM context;
   * `[0x2004] = 0x52455421` (`'RET!'`) — control returned via `RSM`;
   * `[0x2008] = 0x5A4D900D` — the `EBX` witness survived `SMI#`/`RSM`, proving
     `RSM` restored the interrupted GPR state;
   * the QEMU save area @ SMBASE+0xFF00 carries the saved EIP/EFLAGS/CR0 — `SMI#`
     saved the interrupted CPU state;
   * `info registers … SMM=0` — `RSM` completed; the CPU is back in normal mode.

## Deferred differential part + the minimal structural RTL plan

The RTL `--system` differential against a qemu golden is **deferred** because the
oracle cannot trace SMM. The RTL phase (M2S.5 Phase 2) implements the SMM
mechanism and **self-checks it RTL-only**, not against a qemu golden:

* The RTL models `SMI#` entry (save the CPU state to the **P5** SMRAM save map at
  SMBASE+0xFE00; clear `CR0` PE/PG/EM/TS; `CS` base = SMBASE, `EIP = 0x8000`, large
  limits), SMM-handler execution, and `RSM` (`0F AA`) restoring the full state
  (incl. a possibly-modified SMBASE / resume EIP).
* The differential gate is replaced by an **RTL-only assertion test**: the TB
  asserts `SMI#` directly (bypassing the un-traceable gdbstub path), single-steps
  the RTL through entry → handler → `RSM`, and structurally checks the save-map
  contents (at the P5 offsets), the SMM-context register state, and the post-`RSM`
  restoration — the same round-trip this image proves against qemu free-running.
* SMM is gated behind `sys_mode` (user-mode `make verify` stays bit-identical).
* Stepping-specific corners, the I/O-restart / auto-halt fields, and APIC-SMI
  *sourcing* in the RTL front end remain deferred (honest done-partial).

This keeps the iron rules: `make verify` (user) green + bit-identical, all prior
sys tests stay sys-green, and **no sys-diff is ever faked** — where the oracle is
infeasible we say so and self-check structurally instead.

## Phase 2 (DONE) — the RTL SMM mechanism + the RTL-only self-check

The RTL (`rtl/core/core.sv`, gated `sys_mode`) now implements the SMM mechanism:

* **SMBASE** register (reset default `0x30000`) + **RSM** (`0F AA`) decode (RSM is
  `#UD` outside SMM / in user mode, so user-mode `make verify` stays bit-identical).
* **`SMI#` source:** the RTL recognises the APIC self-IPI SMI exactly as qemu's
  APIC does — on the **ICR-low write** (a store to physical `0xFEE00300` whose
  value carries delivery-mode = SMI, bits[10:8]==`010`) it latches `smi_pending`,
  and the SMI is taken at the **next instruction boundary** (not mid-instruction).
  So the SAME bare-metal `psmm.bin` drives the RTL round-trip — no TB poke.
* **`SMI#` entry (`S_SMI_SAVE`):** writes the CPU state to the SMRAM save-state map
  at the **documented P5 offsets** (Pentium Dev. Manual Vol.3 Table 20-1: CR0
  `@SMBASE+0xFFFC`, CR3 `+0xFFF8`, EFLAGS `+0xFFF4`, EIP `+0xFFF0`, EAX..EDI
  `+0xFFD0..+0xFFEC`, the 6 segment selectors `+0xFFA8..+0xFFBC`, GDT/IDT base, the
  SMBASE relocation slot `+0xFEF8`, the SMM revision id `+0xFEFC` written as the
  P5 value `0x00020000` — bit 17 (SMBASE-relocation support) set, bit 16 (I/O
  restart) clear, per Vol.3 §20.1.5.1/§20.1.5.3 + matching qemu-system-i386 —, the
  auto-HALT slot at the documented word location `+0xFF02`); the segment HIDDEN
  descriptor state (base/limit/attr) + the
  table limits go to the RTL-internal reserved-area block at `+0xFE00..` (the
  exact P5 reserved-slot encoding is stepping-specific / not publicly documented,
  so that hidden-state layout is this RTL's own convention — DONE-PARTIAL). Then
  enter SMM: clear `CR0` PE/PG/EM/TS; `CS` sel=`SMBASE>>4` base=`SMBASE`, the data
  segments base 0, all with 4-GiB limits; `EIP = 0x8000`; `CPL = 0`; 16-bit default
  operand/address size.
* **`RSM` (`S_RSM`):** reads the whole save map back and commits the restored
  architectural state in a single clock (honoring a handler-modified SMBASE /
  resume-EIP), then resumes the interrupted context.

**The RTL-only self-check** (`psmm-rtl-selfcheck.py`, run in
`verif/sys/run-sys-golden.sh psmm` step 3d) runs `psmm.bin` on the Verilator TB in
`--system` mode and asserts BOTH the trace records (SMI entry to the SMM context —
`CS=SMBASE>>4`, `CR0.PE` cleared, EIP at `SMBASE+0x8000`; the handler running in
SMM; RSM restoring the mainline `CS`, `CR0.PE`, the EBX witness `0x5A4D900D`, and
the resume EIP) AND the post-run physical memory + the P5 save-state map (read via
the TB's new `--smm-dump`): `[0x2000]=0x5A4D5A4D`, `[0x2004]=0x52455421`,
`[0x2008]=0x5A4D900D`, and the P5 save-map fields at the documented offsets. This
is the same SMM round-trip the qemu free-run check proves — here demonstrated in
the RTL at the **P5** offsets (qemu writes the **P6** layout, so the save area is
not byte-comparable; the round-trip + the documented P5 offsets ARE the check).

**Still deferred (honest done-partial):** the differential golden (the gdbstub
oracle masks SMI / has no SMM awareness — INFEASIBLE, above); the I/O-instruction-
restart + auto-HALT-restart save-map slots (written as 0 / never exercised by the
corpus); a handler that actually RELOCATES SMBASE or modifies the resume EIP (the
RTL commits both from the writeable save slots, but `psmm.bin`'s handler leaves
them unchanged, so only the round-trip-to-saved-value is exercised); the exact
P5 reserved-area encoding for the hidden descriptor state (RTL-internal convention);
**DR6 `@+0xFFCC` / DR7 `@+0xFFC8` / TR (selector) `@+0xFFC4` / LDT Base `@+0xFFC0`**
(Table 20-1 defines these four in the save map; the RTL does NOT save/restore them
across SMI#/RSM — debug registers are M2S.6 and there is no LDT-base register yet;
TR exists but is left unchanged through SMM. The psmm corpus does not modify
DR/TR/LDT in the handler, so the round-trip still closes — a real divergence from
the full P5 save map, deferred honestly); and FPU / DR3–DR0 / the auto-saved TR
state that Table 20-1 leaves implementation-private (not part of the corpus
round-trip). The SMM Revision Identifier slot now carries the faithful P5 value
`0x00020000` (bit 17 set) but is read-only / not restored by RSM.
