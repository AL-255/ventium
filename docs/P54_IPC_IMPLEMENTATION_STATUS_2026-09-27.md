# P54 structural-audit implementation status

Date: 2026-09-27. This records bounded fixes started from
`P54_IPC_STRUCTURAL_AUDIT_2026-09-27.md`; it is not completion of the proposed
PF/D1/D2/EX/WB redesign or the sub-1-CPI objective.

| Change | Micro-test / gate | Integrated evidence |
| --- | --- | --- |
| Default L1 stores mutate only on ACK and only matching physical tags; unrelated ways remain resident (`3037942`). | `bash verif/l1/run-l1d-tag-policy-gate.sh`: 32 offsets × 15 masks, crossing, blocked/cancelled, same-set unrelated way and snoop overlap; L1/L1AXI gates. | Independent DDR2 Quake cold boot to gameplay at 1.15B, same-build continuation to 1.40B. |
| Shared-FPU streaming FMUL has a two-clock initiation interval while independent FADD/integer overlap remains possible (`0e8e5a3`). | `make -C fp_shared test-stream test-fxch-queue`; directed `+p54_fmul_ii2_only` checks accept/reject spacing, ownership, results and stack fault. | Included in the Quake and Win95 candidate binary; no isolated gameplay gain is attributed to this correction. |
| Cold-boot script records optional keyboard input (`b634d8b`); versioned checkpoints permit a save only after the script fully drains, and never replay a script on restore (`f8c1b4b`). This is harness-only. | `bash ao486-sim/ven/run-kb-checkpoint-gate.sh`; simulator smoke tests for completed-input save, mid-input rejection, no-script replay, and scripted-replay rejection. | Validated Win95 300M snapshot and 301M/310M same-binary replays. |

The RTL source after the two fixes passed `make verify` (105 pinned-QEMU
functional programs plus M4/M5 bands), `make verify-sys`, `make lint` (five
profiles), the relevant L1/L1AXI gates, and FP leaf gates. These do not
replace the full `make verify-all` umbrella or an FPGA timing/area run.

The structural candidate binary SHA-256 is
`229c4cd52cba44734335ecb77b3250bee6648c2d153db0f07903060f78160c02`.
Its independently cold-booted Quake checkpoint has 439,870,516 legacy retire
events at 1.15B clocks; the continuation has 546,463,392 at 1.40B. The
measured sustained gameplay IPC is therefore **0.426371504** over cycles
1.15–1.40B, exactly the historical cache-policy control in that window. Five
paired gameplay frames match byte-for-byte. This is not timedemo completion,
and per-element REP callbacks still need normalization to completed
instructions. The checkpoint-capable Win95 harness rebuild has binary SHA-256
`60ffb004f21e34a38e4a924353ca944d077707d405769c9270945acff4dfff52`;
its generated RTL archive is byte-identical to the structural candidate's.

For Win95, a pristine image with pinned boot ROMs and keyboard menu choice 1
was used. Candidate and source-matched pre-fix control agree at all 50M
retirement checkpoints through 500M (109,424,862 events). The checkpoint
capable build saved at 300M (59,427,628 events) and replayed to 310M. Its
IVT13/IVT19 values, EBDA segment and advancing BDA tick match the documented
headless Windows signature; the guest is in the `059f:1e5/1e6` idle path.
The mode-12h framebuffer capture is garbled, so a rendered desktop has **not**
been visually confirmed in this run. A different, previously writable disk
gave the same VxD failure on candidate and control; it is not acceptance data.

Open work: P0's canonical completed-instruction counter and independent
timing model; separate I/D allocation and a pipelined owned memory interface;
banked dual-access D-cache and V-memory lane; staged PF/D1/D2/EX/WB pipeline;
P54 TLB geometry, write-back/coherence, target-bearing branch prediction and
full FP SIR/FXCH timing. Each needs its own directed witnesses, differential
gate, integrated Win95/Quake run, and eventually FPGA area/timing qualification.
The current fixes are correctness/fidelity repairs, not evidence that those
larger performance mechanisms have been implemented.
