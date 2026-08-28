# Quake hardware root cause: untracked ESP RAW pair

Date: 2026-08-28  
Image: `a0486501` (`rk_ao486_fastload.bin`, SHA-256
`5dff8335c4885765dbd6be12e9af02f44eb07d87b9e491968ca7b15a5f34db2d`)  
Disposable test disk baseline:
`qk_td_cwsdpmi_original.vhd`, SHA-256
`616d7c7ebf03b00b6c2031e1e81733e324adb859d91707dd3bf0f6772b2b50e2`

## Finding

**Confirmed high-severity architectural corruption in the system fast path.**
The U/V pairer deliberately removes `ESP` from its dependency masks.  A pair
whose V member reads the `ESP` written by U can therefore issue together, but
the V pipe deliberately reads pre-issue register state.  The V member receives
the stale stack pointer.

The concrete Quake/CWSDPMI occurrence is in 32-bit client code (`CS.base =
SS.base = 0x10000000`), inside the routine entered at `00a7:0004d328`:

```asm
0004d343  29c4              sub esp,eax       ; EAX = 0x34
0004d345  89e7              mov edi,esp
```

`VEN_SYS_FASTPATH_RELOC` makes both unprefixed register forms eligible for the
fast path in this equal-base 32-bit system context.  The core's V pipe uses the
old register file by construction, so this pair is valid only if the pairer
detects the RAW relation.

It does not.  `rtl/core/decode.sv:419-422` currently defines `_onehot` as
zero for `R_ESP`.  Consequently U's write mask and V's read mask are both zero
for this dependency, and `rtl/core/issue_uv.sv:39` accepts the pair.

## Hardware proof

All stops below used the capability-gated instruction-boundary debugger; no
PL-clock freeze, RAM write, or Verilog change was used.

### Normal dual-issue execution

At a breakpoint immediately before `0x4d343`, architectural state was:

```text
EIP=0004d343  EAX=00000034  ESP=0011b2f0  EBP=0011b304
```

After allowing normal execution through the first helper return at `0x4d362`:

```text
EIP=0004d362  ESP=0011b2a8  EDI=0011b2f0
```

`EDI` is the stale pre-allocation stack pointer.  It must have been
`0x0011b2bc` (`0x0011b2f0 - 0x34`).  The subsequent helper interprets EDI as
its destination buffer and copies the client environment over the callee's
saved registers and return address.

The routine then reached its `RET` at `0x4d40c` with the expected pre-RET
`ESP=0x0011b308`, but with its frame overwritten:

```text
[SS:0011b2f0] = 48544150  "PATH"
[SS:0011b2f4] = 43002e3d
[SS:0011b2f8] = 50534d4f
[SS:0011b2fc] = 0011d000
[SS:0011b300] = 4f435c3a  "C:\\CO"
[SS:0011b304] = 4e414d4d  "MMAN"
[SS:0011b308] = 4f432e44  "D.CO"  ; should be 0004d553
```

This explains the eventual ring-3 page fault at the bad return target.  The
earlier CALL itself was independently checked and is correct: stepping
`CALL 0x4d328` at `0x4d54e` changed `ESP 0x0011b30c -> 0x0011b308`, transferred
to `0x4d328`, and wrote `0x0004d553` at `[SS:0x0011b308]`.

### Serialization control

From the same clean disk and identical `0x4d343` stop:

```text
single-step SUB: EIP=0004d345, ESP=0011b2bc
single-step MOV: EIP=0004d347, ESP=0011b2bc, EDI=0011b2bc
run to 0x4d362: EDI=0011b2bc
```

The rest of the function then preserved the frame:

```text
at RET 0x4d40c: EBP=0011b34c, ESP=0011b308
[SS:0011b308] = 0004d553
single-step RET: EIP=0004d553, ESP=0011b30c
```

The debugger intentionally suppresses U/V pairing for a step.  Thus the only
material difference between the failing and passing executions is
serialization of the `SUB ESP` / `MOV ...,ESP` dependency.

## Scope: this is a class defect, not a single Quake address

A static scan of the exact clean-disk `QUAKE.EXE` found six adjacent,
unprefixed 32-bit `ESP`-writer / `MOV r32,ESP` pairs that are all accepted by
the current register-only fast-path decoder.  The run-time addresses use the
same `+0x800` image placement that maps the observed file offset `0x4cb43` to
the live `0x4d343` stop:

| Run-time address | Pair |
|---|---|
| `0x2e0c5` | `sub esp,0x8060; mov eax,esp` |
| `0x44dae` | `sub esp,0x30; mov eax,esp` |
| `0x4d343` | `sub esp,eax; mov edi,esp` (hardware-proven) |
| `0x4f85f` | `sub esp,eax; mov esi,esp` |
| `0x4fe0c` | `sub esp,eax; mov ebx,esp` |
| `0x4fe74` | `sub esp,eax; mov edi,esp` |

Static presence does not prove that every row executes in this workload, but
it proves that single-stepping only `0x4d343` cannot make the bitstream safe:
the same illegal pairing can recur later.  The scan found no matching direct
pair in the shipped `CWSDPMI.EXE`; this particular issue is nevertheless a
core-wide fast-path invariant failure, independent of either binary.

## Proposed RTL fix

The QEMU P5 timing plug-in independently uses `GP_NOSP_MASK` in
`verif/qemu-plugins/p5trace.c:395-402`, so it intentionally models ESP as not
blocking a pair.  Do not casually change that oracle convention: a real P5 may
have a stack-pointer bypass that this RTL does not implement.

The safe, compact repair for this RTL is to make ESP visible to the decoder
dependency masks:

```systemverilog
// decode.sv: replace the ESP-special case
function automatic logic [7:0] _onehot(input logic [2:0] r);
  _onehot = 8'd1 << r;
endfunction
```

Then preserve the existing timing-model treatment of a write/write-only ESP
pair, while blocking every ESP RAW relation:

```systemverilog
// issue_uv.sv: after _onehot includes R_ESP
if ((v.reads & u.writes) != 8'd0) return 1'b0;                 // RAW, incl. ESP
if ((v.writes & (u.writes & ~(8'd1 << R_ESP))) != 8'd0)
  return 1'b0;                                                  // WAW except ESP
```

This prevents exactly the stale-read cases (`sub/add/mov/inc/dec/shl ... ESP`
followed by a V ESP consumer) without disabling unrelated fast instructions or
all ESP write/write pairs.  It costs only the already-present 8-bit dependency
logic and has no new datapath, queue, or broad congestion cost.  Update the
stale comments in `decode.sv` and `issue_uv.sv` that say ESP is excluded.  It
also keeps the existing `addr_mask` AGI mechanism semantically complete if a
future fast-path memory form admits ESP as an address base (the current
register-base load/LEA subset deliberately rejects the SIB encoding for that
form).

### Timing-oracle alignment is required

`verif/qemu-plugins/p5trace.c` currently has the same `GP_NOSP_MASK` rule, so
the corrected RTL can intentionally consume an extra clock at an ESP RAW site
while the cycle oracle still reports a pair.  That must be made explicit; do
not hide it with a compare waiver or a broad `cycle_mode=0` test.  If the RTL
uses the compact interlock above, change the plug-in's pairing condition to
match its actual pipeline:

```c
uint8_t raw = v->reads & u->writes;                  /* RAW includes ESP */
uint8_t waw = v->writes & (u->writes & GP_NOSP_MASK); /* ESP WAW retained */
if (raw || waw) return false;
```

Keep `GP_NOSP_MASK` for the WAW side only and update its comment: this is a
Ventium no-stack-bypass timing rule, not a claim that the P5 necessarily
interlocked the same sequence.  Functional differential traces remain the
authority for architecture; this narrow timing adjustment keeps the cycle
gate honest about the implemented, correct pipeline.  The new targeted
cycle-mode regression must prove both sides: ESP RAW is unpaired, while the
deliberately retained ESP-only WAW case still pairs.

An ESP-only U-to-V forwarding path is a possible later performance refinement,
but it is **not** a safe one-line substitute.  The forwarded value must match
the U architectural write for ALU/MOV, shift, LEA, and fast load forms,
including operand-width merge and stack-pointer post-processing.  The current
V pipe has only pre-issue operands and no such bypass.  Implement it only with
directed testing of every supported form; do not forward `u_alu` blindly (that
is wrong for U shift, LEA, and load).

Do **not** work around this by disabling `VEN_SYS_FASTPATH`, disabling all
pairing, or adding a Quake-address exception.  Those options hide the same
class in other code and impose avoidable broad performance loss.

## Controlled hardware workaround result (not a substitute for the RTL fix)

For causality only, a clean Quake disk was booted to the `0x4d343` breakpoint,
then the unsafe pair was serialised with two debugger single-steps (`SUB ESP,EAX`
and `MOV EDI,ESP`) before normal execution resumed.  The returned `EDI` and
return-frame values were correct, and execution passed the original failure by
more than 44 million retirements (about 194 million total) without the prior
page-fault forensic stop.

This is a deliberately surgical experiment, not a deployable workaround.  A
later safe halt found continuous execution in a real-mode/firmware address
range (`CR0=00000010`, `CS:EIP=f000:e82e`) with blank text-mode capture.  That
later state may be a separate guest handoff or divergence; it is not evidence
that Quake timedemo completed, and it must be traced independently after the
RTL dependency repair is deployed.  The experiment establishes only that the
ESP RAW pair is a real, immediate blocker and that serialising it removes that
specific corruption.

A second controlled run repeated that serialization, then armed a breakpoint
at the next static candidate (`0x4f85f`).  It did **not** hit before the guest
again entered a real-mode `05f7` region; the safe final sample was
`CR0=00000010`, `CS:EIP=05f7:14bf`, after 18,523,638 additional retirements.
The breakpoint was still enabled and never latched.  This is negative evidence
only: that particular candidate is not on this early path.  It neither removes
the core-wide defect nor establishes that the protected-to-real-mode transition
is terminal (CWSDPMI performs legitimate such transitions).  The service was
stopped immediately afterward; the VHD still matched its clean SHA-256.

## Disposable binary bridge toward a real timedemo

`make_quake_esp_safe.py` is a hash-locked, diagnostic-only bridge for two
reviewed clean-disk `QUAKE.EXE` profiles: the retail baseline and the
previously QEMU-proven FASTTICK + no-render + heap-scan + result-marker image.
It redirects the six static ESP RAW sites into the existing 102-byte zero code
cave at file `0x4cf64` (run-time `0x4d764`).  The writer executes normally;
the consumer uses a semantically inert `CS:` prefix, so it follows the slow
path and cannot issue as V with a stale ESP.  The original control flow, stack
adjustment, consumer destination and the first overwritten following
instruction are replayed before a jump returns to the original next
instruction.

This is deliberately limited to proving a full hardware timedemo while the
general core fix is pending.  The script refuses any source except one of the
two named SHA-256 preimages, verifies all six original instruction contexts and
requires the cave to be all zeroes.  It never edits an acceptance image in
place.

### Accelerated disposable deployment image

The first bridge deployment uses the reviewable accelerator profile so the
board can reach the guest's 969-frame witness in practical time without
changing architectural guest control flow.  Its parent executable is
`71985ca618021a90172723c563fb30c3a7a79d4880271fe513b1bc46b7462943` and is
the clean `quake_fasttick_heapscan_marker` composition: FASTTICK, renderer
return, a post-allocation heap-scan bypass, and a result-only `969` memory
marker.  The marker is deliberately not a pre-seeded disk string.

| Artifact | SHA-256 |
|---|---|
| ESP-safe accelerated `QUAKE.EXE` | `c1c94e9b5b03012efce79f37a609afbd8f405697aa4f4d893e91d61946a4701c` |
| never-booted ESP-safe VHD | `b4f6bcc335b4b9a014a62ff32532ae25ec59a36f7a3a2d271772fb05890fad03` |

The VHD was made by a reflink copy of the prior clean accelerator VHD, then a
single FAT replacement of `\\QUAKE\\QUAKE.EXE`.  A subsequent FAT extraction
matched the executable SHA-256 above.  Its `AUTOEXEC.BAT` is still exactly:

```bat
@echo off
fasttick
cd \QUAKE
quake -nosound -nocdaudio -condebug +viewsize 30 +timedemo demo1
```

The source accelerator completed the exact 969-frame workload under pinned
QEMU; the ESP bridge changes only the six affected stack-pointer pairs and its
execution is also architecturally valid on QEMU.  FPGA completion is accepted
only after a fresh, board-produced marker/result witness, never from the disk
preimage or daemon lifetime.

### CWSDPMI composition

The first FPGA bridge run progressed beyond the originally observed ESP
corruption but made no forward progress after a later return to real mode and
was reset by the platform watchdog.  The source disk still carried the known
unsupported protected-mode `LDS` sequence in `CWSDPMI.EXE`; that return is
therefore not evidence that the ESP bridge failed or that Quake completed.

The next disposable image additionally replaces only `\\QUAKE\\CWSDPMI.EXE`
with the independently hash-locked, selector-faithful v4 discriminator from
`fpga_verify_20260822/quake_cwsdpmi_patch`.  Its source and output hashes are:

| Artifact | SHA-256 |
|---|---|
| CWSDPMI v4 executable | `749b94dc3fd5234800e81073d1a6a8cccce259bed54ea38198fe36c99572d35d` |
| ESP-safe + CWSDPMI-v4 clean VHD | `f55f0f6efe1440850cea1109aa5465a64892d2de8cccae9ebe3ad04181945d70` |

Both FAT-extracted programs were independently re-hashed after composition:
the Quake executable remains `c1c94e9b5b03012efce79f37a609afbd8f405697aa4f4d893e91d61946a4701c`
and only CWSDPMI changes from the preceding image.  This combines two narrow,
documented guest discriminators; it is not evidence of an RTL `LDS` repair.

### Post-RTL-repair control disk

`qk_td_fasttick_norender_heapscan_cwsv4.vhd` is the corresponding control for
the general RTL repair: it contains the same accelerated timedemo profile and
the CWS v4 discriminator, but **does not** contain the ESP code-cave patch.
Its SHA-256 is
`5750d36aaee50ed5e37643107a547dbdcd52734a2c549e74507b7dac596ba864`.
FAT extraction independently verified `QUAKE.EXE` as the unmodified accelerator
parent `71985ca618021a90172723c563fb30c3a7a79d4880271fe513b1bc46b7462943`
and `CWSDPMI.EXE` as v4
`749b94dc3fd5234800e81073d1a6a8cccce259bed54ea38198fe36c99572d35d`.
This is the first image to run after deploying the corrected bitstream: reaching
the early `0x4d343` sequence with the post-subtraction `EDI` value demonstrates
that the RTL interlock—not the binary barrier—removes the original corruption.

### FPGA completion after the RTL repair (2026-08-28)

The general RTL repair was built into
`fpga_run_20260828_espraw_r2/rk_ao486_system.bit.bin`, SHA-256
`49d336e21a6d90eb6852312901e366ddc28159de475059cc530567ba909495e8`.
Final implementation signoff was clean: WNS `+2.915 ns`, TNS `0`, WHS
`+0.014 ns`, THS `0`, zero routed-net errors, and zero pre-bitstream DRC
errors.

On the board, an instruction-boundary breakpoint immediately before
`00a7:0004d343` observed `EAX=00000034` and `ESP=0011b2f0`.  A second
pre-issue breakpoint at `00a7:0004d362`, reached without single-stepping the
pair, observed `EDI=0011b2bc`: the required post-subtraction stack pointer.
This is the hardware proof that the generic ESP RAW interlock, rather than the
old code-cave serialization, handled the original corruption.

The control VHD initially matched the immutable SHA-256
`5750d36aaee50ed5e37643107a547dbdcd52734a2c549e74507b7dac596ba864`.
The active guest reached timedemo state and advanced from frame zero to 969 on
silicon.  The completion probe then observed:

```text
QUAKE COMPLETION MARKER 969 (969 frames path) phys=0018fb48 lastEIP=00055efd
```

The marker wrapper is at runtime `0x3fec` and stores `969` at
`DS:0x90b48` immediately before the original timedemo result printer.  The
previous probe default (`0x90b40`) named the unrelated `con_debuglog` flag and
was corrected in `fpga/board-tools/ven_board_probe.py`; use `quake-marker`
with its current default (or explicitly pass `--offset 0x90b48`).  The
workload's logger-return instrumentation intentionally does not require a text
result record on the VHD; this on-chip, result-path marker is the completion
witness.

## Required regression before deployment

1. Add an `issue_uv`/decode regression that decodes `29 c4; 89 e7` and asserts
   `pair_ok == 0`; test ALU, MOV, INC/DEC, shift, and load producers of ESP
   followed by every supported V ESP consumer.  Also assert that a write/write
   pair whose V member does not read ESP retains the intended pair result.
   Extend the direct decode test rather than assuming `verif/decode16` covers
   this: that test currently instantiates only `decode`, not `issue_uv`.
   At minimum, use these byte-exact cases: `29 c4;89 e7` (`SUB`),
   `83 ec 34;89 e0` (immediate `SUB`), `89 c4;89 e7` (`MOV`),
   `44;89 e7` (`INC`), `d1 e4;89 e7` (shift), and `8b 20;89 e7`
   (fast-load configuration).  The positive control must be
   `89 c4;89 dc` (`MOV ESP,EAX; MOV ESP,EBX`): it is ESP WAW-only and must
   remain pairable under the compact interlock.  Do not use `ADD ESP,4; MOV
   EAX,ESI` as a positive ESP control; its second instruction does not read
   ESP, so it tests an unrelated pair.
2. Add an *integrated* `cycle_mode=1` architectural test with a final register
   witness for `sub esp,eax; mov edi,esp`.  The normal functional trace is
   single issue and the existing cycle comparisons emphasize PC/timing, so
   neither alone is a sufficient guard against a paired stale-register read.
3. Run `make verify`, `make verify-sys`, and the cycle gate.  The exact cycle
   count may change only where previously illegal ESP-dependent pairing
   occurred; architectural traces must remain green.
4. Build the deployed KV260 define set and re-run the hardware sequence in
   this report.  In an uninstrumented run, the breakpoint at `0x4d362` must
   show `EDI=0011b2bc`; the breakpoint at `0x4d40c` must show
   `[SS:0011b308]=0004d553` and a stepped RET must land at `0x4d553`.  Also
   spot-check the later static candidates above if their breakpoints are
   reached: each destination must receive the post-write ESP value without a
   debugger step.
5. Continue the clean Quake boot/timedemo and Win95 smoke tests, because every
   system-fast path now sees the corrected dependency mask.
