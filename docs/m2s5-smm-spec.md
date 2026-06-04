# M2S.5 — SMM / RSM (partial oracle)

Fifth system-mode RTL stage. System Management Mode: `SMI#` → save CPU state to
SMRAM → run the SMM handler in a special real-mode-like context → `RSM` restores
and resumes. **Partial-oracle** stage: the SMRAM save-state map layout is
stepping-specific (P5-documented), and the gdbstub exposes SMM only partially —
so the corpus phase **de-risks the oracle first** and scopes honestly.

## De-risk first (corpus phase, gating)

Before any RTL: confirm the differential loop is even possible —
1. Can a **bare-metal test trigger `SMI#` deterministically** under
   `qemu-system-i386`? (Options: I/O write to the ACPI SMI command port `0xB2`, or
   an APIC self-IPI with SMI delivery mode. Find one qemu honors.)
2. Does the **gdbstub single-step cleanly into/out of SMM** (the SMI entry +
   `RSM` are mode changes) and expose the SMM context (GPRs/EIP/CS/CR0 carry the
   SMM-handler state; the SMM-active flag is HMP-only per M2S.0)?
3. Does qemu use the **P5 SMRAM save-map** layout so the saved/restored state is
   comparable?

If SMI can't be triggered/traced deterministically → report it, implement a
**minimal documented** SMM (the mechanism, self-checked structurally) and defer
the differential part. If it works → full differential gate below.

## Scope (if oracle works)

1. **SMBASE / SMRAM** (default SMBASE `0x30000`; save-state map at `SMBASE+0xFE00`,
   P5 layout from the Dev. Manual). `RSM` (`0F AA`).
2. **`SMI#` entry:** save the CPU state to the SMRAM save map at the documented P5
   offsets (GPRs, EIP, EFLAGS, segs + hidden, CRx, DRx, the auto-halt/IO-restart
   fields), enter SMM: `CR0` cleared (PE/PG/EM/TS off), real-mode-like
   `CS = SMBASE>>4` base `SMBASE`, `EIP = 0x8000`, large segment limits.
3. **SMM handler execution** (real-mode-like flat) → **`RSM`:** restore the full
   state from the save map (incl. a possibly-modified SMBASE / resume EIP), return
   to the interrupted context.

## Corpus + gate

- `psmm` — set up SMRAM + an SMM handler (at `SMBASE+0x8000`) that writes a
  sentinel + `RSM`s, then trigger `SMI#` (port `0xB2` / APIC) and verify control
  returned with state intact + the sentinel. Generate the `qemu-system-i386`
  golden. **Gate (if oracle works):** `psmm` RTL `--system` EQUIVALENT across SMI
  entry → handler → `RSM` resume. Else: structural self-check + documented defer.
- **Hard:** `make verify` (user) GREEN + all prior sys tests (pseg/pmode/ppage/
  pintr/pfault/pcpl) stay sys-green; SMM gated behind `sys_mode`.

Honest done-partial expected (entry/RSM mechanism + save-map working; stepping-
specific corners + IO-restart/auto-halt + APIC-SMI sourcing deferred). Never fake a
sys-diff. Next: M2S.6 (debug registers / `#DB`), the last stage.
