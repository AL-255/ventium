# Repaired-LDS Quake silicon result — 2026-08-23

## Verdict

**The protected far-pointer repair passes its silicon discriminator, but the
unmodified Quake timedemo still fails.** The repaired image executes beyond the
old CWSDPMI `0018:00001105` instruction, enters Quake protected code, and later
delivers a page fault after deterministic stack corruption. A final clean,
unfrozen 600-second run completed normally at the daemon level but did not
produce `QCONSOLE.LOG`, `TIMEDEMO`, `969 frames`, or `FLUSHWD` evidence. Disk
reads stopped at 582 for the final 205 seconds, and the exact post-run checker
reported:

```text
elapsed=15s lastEIP=0000e834 last_ar_guest=00001b00
QUAKE TIMEDEMO NOT COMPLETE (timeout)
```

This is a **workload FAIL**, not a partial pass. It does prove that the earlier
protected-mode LDS decode/atomic-commit blocker is closed on silicon.

## Immutable inputs and final acceptance run

| Input | SHA-256 |
|---|---|
| `fpga_run_20260823_lds2/rk_ao486_system.bit.bin` | `013396318e9c385b80c36d43422fa5795c3c50c65615126082ca5ff302eda4b9` |
| clean board disk `/tmp/ao486/qk_td.vhd` | `616d7c7ebf03b00b6c2031e1e81733e324adb859d91707dd3bf0f6772b2b50e2` |

The final service was `ven-quake-context-final.service`. It ran its full 600
seconds and ended with `Result=success`, `ExecMainStatus=0`, and
`ActiveState=inactive`. Those fields mean the board daemon completed; they do
not mean the guest workload passed. The disk hash was unchanged after the run.
The daemon is stopped and the core was not left frozen by this acceptance run.

| Final-run evidence | SHA-256 |
|---|---|
| `quake_context_final_filtered.log` | `fa1896e19671962ea89277d87516b615f77fa008183ff623e84ee225404eb785` |
| `quake_context_final_status.log` | `62625ed9d14261cb063d685836909b2ca07d96a8a66ff32e2648a28c91cbe83f` |

## Direct current-image fault evidence

A live comparator was armed only after read-only progress had qualified the
late protected-mode window. The comparator matches only the low 16 bits of EIP,
so it was qualified with `CS=0x00a7` and the narrow range `0xd5c4..0xd611`.
It froze at current `CS:EIP=00a7:0004d5dc`; the sticky trap status was:

```text
trap frozen=1 frz_eip=00002b73 last_eip=0004d5dc state=27 vector=0e count=0
```

This proves a vector-14 delivery on the current image. `frz_eip=0x2b73` is the
go32 exception stub; the rolling ring's last current client EIP was `0x4d5dc`.
The current capture did **not** expose the original client EIP saved in the DPMI
frame: that frame was still cache-resident when the external freeze stopped the
core, and the DDR snapshot does not contain it. Therefore this report does not
claim that the current faulting client instruction is `0x55efd`.

A separate comparator capture at `CS=0x00a7`, EIP near `0x4ee08`, observed the
DJGPP exception-cleanup path and its later `exit(-1)`. Together the captures
show a deterministic page-fault/cleanup sequence rather than a healthy DPMI
round trip.

The frozen high-memory page corresponding to Quake linear stack area
`0x1011a180` contains long runs of ASCII `0` (`0x30303030`). Its 448 bytes at
high-memory offset `0xe0180` are byte-identical between the early-fault and
cleanup captures. This is stable evidence of a runaway formatting/string path
or stack overwrite before exception cleanup.

| Direct capture | SHA-256 |
|---|---|
| `quake_fault_final.log` | `c0afbc237688a94df74e9b3e0cf2b811e49f61536add5059aa352845c1641480` |
| `quake_fault_final_arm.log` | `33136596daa3299dde3f29c8b11c5fbe745cb952a4fb6da5a64a82afc1fe97ca` |
| `quake_fault_final_ring.log` | `95f238acae75e7a5f6a300f88fdbe0f6d8e81e22bca8e287944ba5d01634b1d9` |
| `quake_fault_final_status.log` | `0ec8bf39601f62ff7edb2b053df93b3b565ca991dde9458ed89fcafe5ce1293e` |
| `quake_fault_final_lowmem.bin.gz` | `92348b07adeff0f36584fd289a14a9f0f8f9b00f5471471ea278f9eb1020cce5` |
| `quake_fault_final_highmem.bin.gz` | `5d694a5f6d43f9cc1df13c627dac98f99c7cecac53df927d1b94651fd9e1f245` |
| `quake_lds_cmp1.log` | `b2f49ba9eae8f1ebcba106621064196568475568ed70cb05744b95efa2cddf8e` |
| `quake_lds_cmp1_ring.log` | `f69407683dcfa284102ff0d4f006bf5d54a789ea255585eee9f455d1f57a8f31` |

## Historical correlation, not current proof

The July full-system cosimulation log at
`/home/yukidama/external/ventium_run/tmp/qk_fx2.log` records an exceptionally
similar failure. It reports a page fault at client EIP `0x00055efd` with
`EBP=0x0011a220`, `ESP=0x0011a214`, `CS=0x00a7`, and the same large
`0x30303030` stack pattern around linear `0x1011a1c0`. That historical failure
was traced to x87 EMPTY-source handling in the then-current
`ao486-sim/ps/x87_cosim.cpp`: a stale physical stack slot was consumed instead
of the masked real-indefinite QNaN, the dtoa digit loop overran its stack
buffer, and a later `REP MOVSD` at `0x55efd` crossed an invalid page.

That mechanism is a strong lead for the current image, but it is not yet the
current root-cause proof. The present RTL has subsequently gained shared
`det_*` stack-fault classification, issue-time `fp_cap_stkflt`, and
`QNAN_INDEF` substitution. The remaining failure could be an uncovered source
kind, a control-word race, or another producer of the same corrupted decimal
string. A source-matched exact-profile reproduction is required before changing
RTL.

## Open RTL risk found during the audit

The `VEN_FP_PIPE` deferred request captures rounding control (`fp_cap_rc`) but
does not capture precision control (`fctrl[9:8]`). Both the split stage-1 and
stage-2 evaluators use the **live** precision-control bits at commit time:

- `f_eval_s1(..., fpp_rc, fctrl[9:8], ...)`;
- `f_eval_s2(..., fpp2_rc, fctrl[9:8])`;
- the unsplit fallback similarly evaluates with live `fctrl[9:8]`.

A following `FLDCW`, `FLDENV`, or `FRSTOR` can therefore make a deferred
operation round under a different precision than it had at issue unless another
serialization rule proves the sequence impossible. `fp_pipe_rd_haz` only names
read-after-write dependence on the in-flight x87 destination; it is not by
itself a freeze of the x87 environment. Quake's conversion code changes the
control word, making this a plausible race that needs a focused test.

The compact repair, if the gate confirms the race, is to add the two PC bits to
the existing owner/capture record and use that captured field through every
evaluation stage. Do not add a second evaluator, a per-opcode stall network, or
a private FLDCW bypass. The eventual shared x87 service request should carry
`{owner, op, a, b, rc, pc, stack_fault, destination}` as one immutable token.

The surrounding documentation is also stale: `rtl/fpu/fpu_x87_pkg.sv` and
`verif/fpu87/confirm_pc24.py` still describe non-default precision control as
unsupported/ignored even though current round/pack paths implement PC24/PC53.
Update those statements only after the exact behavior and gate matrix are
reconfirmed.

## Proposed debug and repair sequence

1. Build a source-matched full-system Verilator target with the exact deployed
   define set: `SYNTHESIS`, `VTM_NO_DPI`, `VEN_CORE`, `VEN_L1_AXI`,
   `VEN_KV260_SOC`, `VEN_L1_HONOR_CD`, `VEN_TRANSCENDENTAL`, `VEN_SRT_ITER`,
   `VEN_IDIV_ITER`, `VEN_BCD_ITER`, `VEN_FP_PIPE`, `VEN_BTB_PIPE`,
   `VEN_CACHE_HALF`, `VEN_IC_NARROWB`, `VEN_ALTSYNCRAM_XPM`, `VEN_DBG_CORE`,
   `VEN_FP_PC_RELAX`, `VEN_SYS_FASTPATH`, `VEN_FAST_RETRACE`,
   `VEN_KBD_AUTOACK`, `VEN_KBC_FAST`, and `VEN_FPREM`.
2. Add a simulator-only rolling x87 trace containing decoded operation, physical
   stack indices/tags, source values, control word, stack-fault token, request
   owner, state, and committed result. Do not add this instrumentation to the
   synthesized datapath.
3. Reproduce Quake and compare the final 512 x87 micro-operations before the
   decimal-string growth against QEMU and the historical trace. Assert that no
   EMPTY source enters the shared evaluator without the stack-fault token, and
   that `{rc,pc,stack_fault,destination,owner}` remains issue-stable through
   commit.
4. Add a focused dtoa regression that replays the exact x87/control-word
   sequence, places canaries around the conversion buffer and stack, and bounds
   the produced string. Run it in the exact FPGA profile, default profile, and
   `VEN_FP_PIPE2` profile.
5. If an EMPTY-source hole is confirmed, extend the one existing `det_*`
   descriptor and `QNAN_INDEF` commit path. If the PC race is confirmed, add PC
   to the same request token. In either case, delete any superseded local
   predicate; do not create a second stack-fault or arithmetic cone.
6. Pass focused x87 gates, five-profile lint, `make verify`, `make verify-sys`,
   `make verify-all`, and the exact full-system profile before another FPGA
   build. Only the unmodified disk's exact 36-byte, 969-frame record closes
   Quake.

No Verilog was modified during this deployment/debug pass. The only source tool
change is the safe `--live` arming mode in
`fpga/board-tools/ven_board_trace_arm.py`; its procedure and constraints are in
`HOW_TO_RUN_FPGA.md`.

## 2026-08-23 continuation: LDS revalidation and x87 PC-race disposition

The exact protected-mode LDS repair was rerun from the current LDS-specific
Verilator binary (`verif/tb/obj_dir_lds/tb_ventium`) against the pinned QEMU
system oracle.  Both required discriminators passed:

- `pseg`: 90/90 architectural records equivalent, including the exact CWSDPMI
  `66 67 C5 75 10` form in a 16-bit protected code segment;
- `pdescprec`: 2,568/2,568 records equivalent, including the not-present
  descriptor case in which LDS must leave its poisoned ESI destination
  unchanged.

This independently reconfirms the decoder and atomic two-destination commit;
the current FPGA workload failure is not grounds to reopen that repair.

The initially plausible `VEN_FP_PIPE` precision-control concern was also
reviewed against the *deployed* define profile.  `fpu_writeback.sv` does read
`fctrl[9:8]` at deferred evaluation rather than carrying it in the request
record.  That is a genuine design hazard for `VEN_FP_PIPE2`: stage 2 can observe
a control-word write that occurred after stage-0 capture.  It is **not a proven
cause of this image's failure**, however.  The deployed `lds2` image enables
`VEN_FP_PIPE` but not `VEN_FP_PIPE2`; its sole deferred result evaluates and
commits on the immediately following edge.  A following `FLDCW`, `FLDENV`, or
`FRSTOR` cannot complete a control-word write before that commit in the
in-order FSM.  No PC-token patch, added stall, or extra evaluator was made for
the one-stage image.  Any future two-stage profile must capture PC alongside
RC and gain a directed control-word-after-arithmetic test before deployment.

### Clean no-flush negative control

The clean result-only disk was restored byte-for-byte on the board (SHA-256
`13f0a1286ceb0da61ddb2f2f20cacdcabbe585dc2967ba39df3a519463795509`) and
run on the deployed `lds2` image **without** `--stall-flush`.  It consistently
booted through IDENTIFY and the boot-sector read, then stopped making IDE
progress at exactly 385 reads.  The live PC ring remained in a coherent
real-mode FreeDOS path, `CS=05f7`, linear addresses `0x00009c49..0x000108ab`,
while the on-board counter sample measured 170,253 retired instructions in
5.000090 s at 3.125067 MHz (IPC 0.010896).  Timedemo counters remained zero.

This establishes that the earlier watchdog's hundreds of global invalidations
did not *cause* the low IPC; without it the same pre-Quake disk-read stall is
deterministic.  The watchdog sometimes changes the subsequent path and is
therefore a diagnostic perturbation, not a valid performance or coherence
repair.  The stopped no-flush log is retained on the board as
`/dev/shm/quake_final_clean_noflush_stalled.log`, SHA-256
`7b5adfa83f76bfddb39f14b081ae8dcf4f52eafbf754916a338576f6c68fb1f6`.

### Correction: the 385-read phase is not, by itself, a corruption proof

The no-flush capture was frozen and a coherent 2 MiB DDR snapshot was copied
read-only from the board.  It contains an intact FAT16 root directory at guest
`0x0008e270`: `KERNEL.SYS`, `COMMAND.COM`, `AUTOEXEC.BAT`, `QUAKE`, and
`FASTTICK.COM` match the expected disk layout.  The captured `CS=05f7`, linear
`0x0000fe47` instruction decodes as a normal FreeDOS pathname routine (`call
0x08c1` after testing the drive-colon byte), not execution of corrupted data.
The earlier bounded `COMMAND COM` scanner can therefore only be used as a
heuristic and must not be presented as evidence of a corrupt in-memory root
directory.  Disk quietness at 385 reads is compatible with CPU-only program
initialization; the clean no-flush endurance run must be allowed to progress to
a Quake-specific witness or an exact result before it is classified as a
failure.
