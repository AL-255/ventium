# Actual prior-clock AGI producer mask (Sep 29)

`VEN_P54_AGI_WRITE_MASK` is implemented, built, and independently reviewed.
It is optional; macro-off retains the previous `agi_wr0/1` behavior. After
COMMON exceeded the 2.0 CoreMark/MHz gate, bounded directed qualification was
authorized. All fourteen whole-core QEMU-state/AGI fixtures passed on the
corrected combined binary; full-system/standard-suite acceptance remains
pending. The user requested a conclusion, so no new runs are being launched.

## Hardware and ownership

`rtl/core/core_agi_write_mask.svh` adds eight flip-flops sampling the existing
fully gated `gpr_we` authority every clock. It does not reconstruct issue,
execution or write permission. Slow MUL/DIV's EAX+EDX, EXT/IMUL destinations,
paired explicit outputs, partial/high-byte parent-register writes and explicit
ESP destinations therefore become real AGI producers automatically. An actual
no-write clock clears every old bit, rather than retaining a stale issue token
through an EX/cache/fault/debug hold.

Intel AP-500 241799-002 section 5.2, printed page 8, says that a base/index
written in the immediately preceding clock incurs AGI in either pipe. It
explicitly exempts implicit PUSH/POP writes to ESP from a following
address-through-ESP AGI. The mask clears only that bit for state-owned literal
PUSH/POP. POP ESP retains its explicit popped destination. POP reg!=ESP retains
the other register's destination. POP memory/segment uses implicit ESP even
when irrelevant decoder destination scratch happens to name ESP. CALL, RET,
ENTER, LEAVE, PUSHF/POPF, PUSHA/POPA and unknown stack writers are **not** given
that exemption without further primary evidence. A paired V explicit ESP
destination defeats U's implicit exemption (current PUSH/POP descriptors are
NP, but the producer must not assume that forever).

Reset/snapshot reset, incoming task/SMM context install and string rollback
clear history. Genuine context restore/rollback values are not executed
producers. Macro-on fast shift physical writeback now suppresses WE for
`u_shift_cnt==0`, matching the existing fast flags and slow reference shift
guards. This is not a general equal-value-write filter: `MOV EAX,EAX`, for
example, still contributes its actual WE. A nonzero rotate which returns the
same value is not suppressed merely because its result is unchanged.

Consumers are the existing isolated `pipe_agi` cone and exact reference
`d_addr_mask` admission (plus its profile-only umap reference). Existing paid
prefix-D1 overlap remains; no EX clock or memory occupancy is shortened.
Experimental prefix EX-chain's *same-clock* `d_addr_mask & gpr_we` veto is
unchanged. Decoder, event, fault, SMC, tag/way/collision and ownership guards
are unchanged. Default-off dual-memory profiles still need independent audit
of prior-clock dependencies in the V address lane before general enablement.

## Verification

`verif/issue_uv/tb_p54_agi_write_mask.sv` includes the actual production helper,
not an independently retyped policy. It exhausts all 256 supplied write masks
over fast/slow PUSH/POP, explicit POP ESP, memory/segment POP, retained paired
V ESP, actual slow dual outputs, conservative non-PUSH/POP stack effects,
stale-q rejection, context and rollback. Sequence checks cover previous write
followed by a zero-write clock and reset. It proves storage/classification,
not the full-core writeback producer or cycle timing.

`t_agi_write_mask.s` prepares fourteen whole-core cases: implicit PUSH/POP,
explicit ESP, POP ESP, ordinary dependent base, high-byte/word parents,
slow EXT, MUL/DIV dual outputs, XCHG ESP, zero-count shift, no-write separation
and independent address. `run-p54-agi-write-mask.sh` selects one with
`CASE_ONLY=0..13`, requires a prebuilt `TB_BIN`, and uses a distinct `PORT` for
parallel jobs. It checks full-state QEMU and reports 900 warm actual consumer
spacings; true unprefixed dependencies have a two-clock minimum. It never
launches a Verilator build. The prepared real-include leaf runner is
`run-p54-agi-write-mask-leaf.sh`, capped at 120-second compilation/15-second run.
All fourteen fixtures were assembled and passed against
`/tmp/obj_dir_cm_p54_combo_fixed_sep29/tb_ventium`; exact result summaries and
traces are in `/tmp/ventium-prefix66-fixed-quick-sep29/summary.json` and its
`common-*-pad00` folders. The observed warm spacings were one clock for the
documented implicit PUSH/POP ESP cases, two clocks for explicit ESP,
high-byte/word parents, slow EXT and MUL/DIV output address dependencies, and
one clock for the zero-count shift. The reference decoder/datapath remains the
authority; these spacings are actual retirement results, not deferred penalties.
The shared leaf was also run by the matrix agent; its detailed evidence belongs
to the parent's concluding gate report.

The older `core_prior_write_mask_proposal.svh` is superseded: its broad implicit
stack exemption was rejected and must not be integrated.

## Existing-trace estimate, not a measured saving

Read-only analysis of the existing performance10 QEMU PC/byte trace found
191,781 adjacent writer/consumer pairs where the only address overlap was
implicit PUSH/POP ESP. Filtering out CALL/RET and other slow consumers leaves
156,606 likely-fast opportunities (65,271 PUSH-to-PUSH, 60,422 POP-to-POP,
19,208 PUSH-to-MOV, 10,241 POP-to-MOV, 1,450 POP-to-PUSH and 14 PUSH-to-LEA).
The classification is a software estimate, not the production decoder or RTL
clock history. Frontend/memory bubbles can absorb these dependencies; there
are also newly restored slow/explicit-ESP hazards. No clock saving or CM/MHz
claim follows until matched measured runs complete.

The parent reported predecessor PREFIX-only 1.992748 CM/MHz and COMMON
2.053795 CM/MHz: approximately **+3.06% score / −2.97% cycles** in those short
diagnostics. This is not an eligible 10-second official score, gameplay IPC,
or an instruction-trace estimate; later bundled features have separate results
in the concluding report. Functional standard-suite acceptance remains deferred,
not waived. Current gameplay IPC is unmeasured; the older verified baseline is
0.45746656 on build `3237b652`, cycles 1,150,151,638–1,400,151,638.
