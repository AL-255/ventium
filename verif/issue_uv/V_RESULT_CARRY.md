# V-pipe arithmetic carry cut — 2026-10-15

**Private timing candidate, not accepted or deployed.** The hardware change is
one expression in `v_pipe.sv`: call `alu_result(..., 1'b0)` instead of forwarding
U's CF into the arithmetic result. `flags_next` still receives the real
forwarded EFLAGS, so V INC/DEC preserve U's new CF. Decoder, issue eligibility,
memory ownership, commit gates, registers and cycle timing are unchanged.

The preceding wait-cofactor candidate synthesized to **37.9507 MHz** at the
unchanged 40 MHz constraint, with a worst path through U CF → V result → GPR.
This cut targets that path. **This candidate has no synthesis/routing result
yet**, and the parent's frequency must not be assigned to it. Equal cycles
are expected: this is an Fmax experiment, not a claimed IPC improvement.

## Safety argument and scope

Actual decode/issue requires `pairs_second`; ADC/SBB are U-only. No other
`alu_result` operation consumes carry. Removing that unused result dependency
does not remove the architecturally necessary CF forwarding for INC/DEC flags.
A simulation-only assertion checks every accepted V descriptor, including held
memory pairs, and rejects ADC/SBB or a missing `pairs_second`. Optional
`+ven_v_result_carry_witness` prints those accepted descriptors.

`prepare_v_result_carry.py` accepts only two exact predecessor hashes and
rejects drift/reapplication. The second changed file, `core.sv`, contains only
the nonsynthesized assertion/witness. The dirty checkout's production RTL is
untouched; the change lives in the reproducible private candidate.
`VEN_P54_REGMEM_PRIME` remains **disabled**, matching the parent. It was not
enabled to improve coverage or performance.

## Closed verification

Evidence root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
Directed parent: `c9e4b9f86ad080f72ffd8ecef3d4ffc73eb1ecb8574ba7cd185bcae4fa3a643a`.
Directed candidate: `a8e5d55b7704f2449002c71af8db1c5c2fe7ae908669fc5dbf2e663d3a59ff73`.

| Evidence directory | Result |
|---|---|
| `v-result-carry-leaf-r3` | Both profiles pass: 13,058,058 decoder and 18,724,320 arithmetic cases total; four deliberate mutants rejected; 26.81 s |
| `v-result-carry-core-r1` | Native build closes 0 in 19.65 s; all 195 source files audited, original 153 defines, private host object/header verified |
| `v-result-carry-system-r1` | 144 cold paged fixtures × AXI latency 0/7; 69,312 candidate records, 3,840 subject V retirements; 14.22 s |
| `v-result-carry-held-r1` | 24 fixtures × latency 0/7; 9,200 records, 1,360 V retirements; actual held-read witnesses retained |
| `v-result-carry-mixed-r1` | 36 U-load/V-store fixtures × latency 0/7; 240 V stores, immediate value readback, 1,140 held and 312 paired-read witnesses; 9.95 s |
| `v-result-carry-integer-r1` | 256 fixtures × latency 0/7; all 1,024 A/B measurements pass; no cycle changes; 32.05 s |
| `v-result-carry-fp-r1` | 384 fixtures × latency 0/7; 208,128 candidate records; all 1,536 A/B measurements pass; 50.16 s |
| `v-result-carry-boundary-r1` | Original 22 fetch-boundary fixtures × latency 0/7; 21,832 records, 4,968 V retirements; 29.45 s |

These whole-core runs compare complete architectural state against QEMU and
require exact parent/candidate state and cycle records. They use UV + fast
pipeline, `cycle_mode=1`, actual `--l1-axi`, relocated clients and fast
load/store definitions. No STEP, intended-V breakpoint, saved state or guest
patch is added. Pairable subjects must actually retire in V; RAW-dependent and
ADC controls must remain unpaired. Every native owner closed successfully;
none of these results counts as the standard suite or physical FPGA acceptance.

The leaf checks all opcode/ModRM/applicable-SIB combinations in both code
sizes/cycle modes, exhaustive byte arithmetic and wide operand corners, both
incoming carry values, immediate/register forms, and enabled pairing classes.
It includes **624,144 INC/DEC-with-CF=1 cases** across two profiles. Mutants
clear the required flag carry or admit ADC to V; both are caught per profile.
R3 actually admits 1,676,236 V cases in the current profile and 1,290,089 in the
baseline profile. Leaf proof alone is not whole-core or formal equivalence.

Keep failed/superseded history: R1 stopped before compilation because the
driver incorrectly required disabled REGMEM. R2 passed arithmetic but its
broad sweep did not exercise pairing (only four final directed pairs).
R3 explicitly settles/checks a decoded U NOP and requires >1,000 broad-sweep
paired cases. **R2 is not qualifying evidence.**

Five recipe/leaf host tests and four full-PC transfer tests pass. The latter
reject wrong/extra source changes, altered posted transport or definitions,
missing subject pairs and missing held/mixed witnesses.

## Full-PC transfer and remaining work

`fpga/build_v_result_carry_soc.py` transfers only the two tested deltas onto
the current AUX-corrected full-PC parent
`70c8de9eb55fda79b9fe359553ebd0b73de1e865c61414773000354edaff7b57`.
All 102 shared core/FP sources and the 157-definition profile are checked.
The PS/2 AUX ownership repair is retained byte-for-byte; an older peripheral
source is not substituted. `v-result-carry-soc-r1` is prepared; native PC
compilation, hardware export and timing are pending.

Canonical `make verify` is running separately with the unmodified oracle,
masks and bands. The parent's canonical gate is red; the directed passes above
do not waive it. Full canonical/system qualification, both error-free standard
CoreMark seeds, completed Quake timedemo, and Win95 desktop remain open.
Matching physical FPGA Win95 cold boot plus keyboard/mouse interaction and a
complete Quake timedemo remain required before completion.

Current candidate gameplay IPC is **unmeasured**. Older verified baseline:
**0.50520554 total U+V**, model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`,
cycles **5,600,065,237–5,700,065,237**. It predates this candidate.

## Evidence storage

Eight unpinned precompiled headers from the two closed leaf builds were removed
(659,150,526 bytes; regenerable). Closed integer/FP traces were compressed only
after every archived member's SHA-256 and size matched its original; binaries,
sources, commands, native logs, comparisons and receipts remain in place.
Archive: `v-result-carry-integer-fp-traces.tar.zst`, SHA-256
`51dc42ee9d88bafd005eef49691edb5d81362a32e47cc501fee42056eea84cf1`;
610,306,448 raw bytes → 1,722,077 archive bytes. Restoration instructions and
per-file hashes are in `v-result-carry-trace-storage.json`. No live run,
accepted image or source was deleted.
