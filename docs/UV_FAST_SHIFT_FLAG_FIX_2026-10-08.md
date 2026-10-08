# UV + fast-pipe shift/Jcc repair — 2026-10-08

## Scope and defect

The U execution unit committed width-aware shift flags, but `uv_common.sv`
independently calculated the flags forwarded to a paired V conditional branch.
Its copy always used bit 31 for SF/OF and treated ROR as a shift that changes
SF/ZF/PF. Thus the architectural flags could be correct while the simultaneously
executed branch took the wrong path. Both affected features are enabled in the
deployed 107-definition simulator / 110-definition FPGA profile.

- Byte/word SHL/SHR/SAR/SAL: forwarded SF and OF used the wrong bit position.
- Dword immediate ROR: forwarded SF/ZF/PF were incorrectly replaced instead
  of preserved. The first-row ROR failure can occur even when U commits the
  correct preserved flags.
- CL shifts are non-pairable in the decoder; no unsafe pairing is enabled to
  cover them. Count-zero flag preservation remains required.

This is a genuine UV-specific functional bug, **not proof of the cause of the
FPGA's separate CMP `14562 ->14563` failure**.

## Fix technique

`ventium_alu_pkg::fast_shift_flags` is now shared by U commit and V-branch
forwarding. It reuses the existing shift result, previous result and carry;
there is no extra shifter, register, stall or execution cycle. It uses the
architectural operand width and preserves the non-CF/OF flags for ROR.
Normal zero-count behavior, count masking and pair admission are unchanged.
No Quake addresses, opcodes at fixed PCs, save-state edits, STEP operation or
U-only/slow-mode workaround are involved.

## Reproduction and verification

`bash verif/issue_uv/run-uv-shift-flags.sh` tests actual decode, U execution,
pair admission and V-branch forwarding against an independent bit-at-a-time
oracle. It sweeps byte/word/dword forms, counts 0–31, ten operands, all 64
arithmetic-flag combinations and all defined Jcc outcomes. Undefined CF/OF
conditions are explicitly excluded, not assigned convenient golden values.

| Profile | Branch checks | Before repair | After repair |
| --- | ---: | ---: | ---: |
| Immediate shifts, ROR disabled | 2,140,160 | 51,968 mismatches | 0 |
| Immediate shifts + dword ROR | 2,352,640 | 127,424 mismatches | 0 |

Evidence under `/home/yukidama/external/tmp/`:
`ventium-uv-shift-flags.LZtPUI` (failing native controls) and
`ventium-uv-shift-flags.qSte6z` (passing repair). A preliminary width-warning
compile failure is retained separately in `ventium-uv-shift-flags.mw4Pi0`.
Only eight rebuildable precompiled-header files were removed after all four
build/run processes closed; executable binaries, source pins and logs remain.

Full-core candidate `ventium-uvflags-full107.XuEzFb` is a private copy of the
previous frozen full107 candidate with only the three repair files overlaid.
No canonical simulator or unrelated working-tree RTL is substituted. It uses
the exact previous 107 definitions, including the system fast path, relocated
clients, fast loads/stores and U/V dual issue. The final independent control
and repair builds also enable assertions and all six structural lint errors.
Both build/input checks close 0; the 32-job compiles take about 8 seconds each
within the fixed 16 GiB scope.

| Isolated full107 build | Executable SHA-256 | Full-core branch tests |
| --- | --- | --- |
| `obj_control107` | `bf7ef0d081f432f20d83c6f0c61f6ece32f6d8dbb651897b9c7093a40c3557ba` | 32/32 wrong-path failures |
| `obj_repair107` | `c50c221dd9649576abe10162ac448294ad92be4b131c2f9088230441f048681c` | **32/32 pass** |

`verif/issue_uv/run-uv-shift-branch.py --tb PATH` adds eight separately linked
programs and 32 full-core runs (AXI latency 0/7, cycle and cycle-functional
traces). Every program must exit successfully in pinned Pentium QEMU. The RTL
must follow the same instruction path, match QEMU's subject/branch/terminal
architectural state, and show U then V in the same cycle with the producer's
V paired marker. Both RTL trace modes use `cycle_mode=1`; no debugger is used.
The old binary's initial run reaches the failure path for all eight programs;
the initial diagnostic reports the consequent wrong terminal INT80 address.
The final, isolated-object control also fails all 32 cases on the wrong
architectural path, while the isolated repair passes all 32. Final evidence:
`ventium-uv-shift-branch.ppy8xulv` (control) and
`ventium-uv-shift-branch.px3dizdu` (repair). The grader additionally rejects
build records missing the required fast-pipeline definitions.

The isolated repair also passes **8/8** existing CPL3 tests: baseline and
D-cache-conflict CMP/JNE fixtures at AXI latencies 0/7, in both trace modes.
Their four cycle traces contain **640** actual same-clock U/V pairs; the
four state traces check all outcomes. Evidence: `cpl3-regression-isolated/`
under the full107 root. This does not erase the separately recorded I-cache
conflict fixture's missing paired coverage.

### Verification-build correction and broader gate status

The first `make verify` invocation against the SoC-addressed full107 binary
reports 95/108 functional passes and one cycle-band failure (`mb_dmiss`). All
13 functional failures reproduce identical architectural traces on the prior
binary and all report the SoC router rejecting Linux-user stack addresses
outside its aperture. The `mb_dmiss` control and repair cycle traces are also
identical (last cycle 4154). **That gate remains FAIL**, not a waived pass.

Trying the established full-address user verification configuration uncovered
a separate host-build defect: generated make's `VPATH` found the external
`tb_reset_edge.o`, whose dependency file named the October-5 model headers.
It skipped recompiling the harness for the new class layout, causing a host
crash during the constructor diagnostic, before CPU execution. This first
full-address run's 0/108 result is invalid as an RTL functional measurement.
The first SoC-directed tests were therefore repeated independently too.

Each final control/repair uses a private, uniquely named C++ translation unit.
The build checks the local object exists, its compilation actually appears in
the native log, and its dependency file uses that build's model header. The
authoritative 32/32 result and CPL3 results above come from these rebuilt
executables, not the reused object. No board image is affected.

The board-only private probe does not compile against the non-SoC top (`intr`
and `inta` are absent); that failed compile is retained. The full-address
verification model instead uses a private copy of the ordinary repository TB,
with only `VEN_KV260_SOC` omitted from the RTL definition set. All UV/system
fast-path features remain enabled, and no guest address or golden is patched.
Its preliminary `--cycle-func --l1-axi` smoke run closes 0. Its broader
`make verify` rerun passes **108/108 functional programs** but remains **FAIL**
on the same `mb_dmiss` cycle band (4154 versus reference 20524 clocks). No
cycle tolerance, reference or assertion is changed to conceal this. The
ordinary gate's functional-only runs are additional diagnostics, **not
replacements for actual UV-path acceptance**. Evidence: `verify-user-r2.log`
and `verify-user-r2/`; this full-address executable's SHA-256 is
`6cc015fc1d2b7ad2707282244d7ee7be233432d067cf8ffa0a0c8e6a3f010d07`.

## Acceptance still open

No FPGA bitstream is rebuilt or deployed for this repair yet. The original
cold 40 MHz Quake run remains failed; Win95/CoreMark/complete Quake acceptance
has not been earned for this change. No performance gain is claimed from
directed tests.

Current repaired RTL and deployed `1c8f20ac` have **no qualified gameplay IPC**.
Historical `53f129e9` baseline: **0.165995778 primary/U-counter IPC**, not total
U+V, over 127 qualified intervals with gaps within cycles
8,721,490,845–19,169,282,165 at 37.499869765 MHz. It predates this repair.
