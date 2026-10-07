# Relocated CPL3 memory-SUB / JNE cache-line-boundary regression

Directed diagnostic; **not a Quake timedemo or standard-suite pass**.
All RTL/hardware runs must retain `cycle_mode=1`, the frozen system fast
load/store/relocated profile, and actual UV pairing. No STEP or execution BP.
Do not turn a missing paired-path witness into a functional-mode pass.

The 53 literal bytes at guest `59662..59696` preserve the sequence implicated
by the October 7 FPGA page-fault capture. In particular, `MOV EBX,[EBP-50h]`
ends the preceding 32-byte line; `SUB EBX,[EBP-24h]` starts at `59680`, and
`JNE 59693` is at `59683`. An interior `59682` is never a valid successor.
The fixture uses normal CPL3 segmentation, page tables and cacheable memory,
not a restored snapshot, forced ACK, injected cache value, or production patch.

Four immutable ROMs each run 64 cases: zero results twice, positive overflow,
negative overflow, repeated 16 times. They check the branch, EBX/ECX/EBP/ESP,
case count, taken count and success marker before `INT 80h` exits to CPL0.
Variants add (1) read/write adjacency, (2) a congruent instruction-cache
caller, and (3) the preceding indirect CALL / ADD ESP shape. Variant 0 is
the plain chain. The callbacks/checking epilogues are synthetic, not Quake.

`bootstrap_legacy.S` intentionally retains **unexecuted** earlier CMP/JP
sections to reproduce the already-measured ROM hashes. Its header describes
that old fixture, not this workload. The new bootstrap copies `sub_client`
and `sub_warm_page`, then IRETs to `59000`; the old client is not entered.
Do not infer CMP/JP coverage from this test or change the old sections without
regenerating and requalifying the ROMs. The exception logger at physical100
publishes its magic last; a nonzero record is a failure here.

Build into an existing empty scratch directory:

```sh
case_dir=$(mktemp -d /home/yukidama/external/tmp/ventium-subjne-roms.XXXXXX)
bash verif/sys/tests/psubjneuv/build.sh "$case_dir"
```

The pinned `qemu-system-i386 -cpu pentium`, with each ROM as BIOS and
`isa-debug-exit,iobase=0xf4,iosize=0x04`, must terminate with native status
133 (AL=42h). All four did. This reference is architectural, not a UV model.

RTL run arguments: `--system --l1-axi --cycle --x87 --max-insn 64000
--max-cycles 2000000 --quiesce 200000`; each process capped at 180 seconds.
The passive `sub_owner_probe.h` and `exception_log_probe.h` hooks were linked
against the unchanged frozen generated model, not the dirty live checkout.
Observer environment: `VEN_PRELUDE_START_PC=0x59000`,
`VEN_PRELUDE_OUT_PC=0xf0260`, plus distinct `VEN_PRELUDE_OWNER_LOG` and
`VEN_EXCEPTION_LOG_FILE`. The owner hook samples before the rising edge;
registered DPI retirement appears one cycle later. These hooks depend on
the pinned model's public signal/packed-descriptor ABI; do not reuse them
against an unqualified layout. Existing build-scope limits remain required.

`check_sim.py STEM` consumes the closed `.vtrace`, `.owner.jsonl`,
`.exception.jsonl`, `.log`, and `.native-exit.txt`. It requires 64 same-cycle
U/V SUB/JNE retirements, exact successors, forwarded arithmetic flags,
retained lengths 3/2, normal translated load address/data and no exception.
This frozen DPI labels the primary U record `paired:false`, and the V
record `paired:true`; same-clock adjacency plus the internal commit/pair
witness establishes actual pairing. On real hardware, OUT is serviced and
HLT retires: the final EIP is `f0262`, **not** the simulator's pre-OUT `f0260`.

October 7 evidence: all 32 variants × AXI-latency cases (0,1,2,3,5,7,11,13)
passed, with 2,048 paired subject commits. Variant 0 also passed all 64
self-checks on `6659e0c5` at measured 39.999865 MHz, with no STEP/BP and an
adjacent-primary-ring witness spanning the paired JNE. Hardware variants
1–3 were **not run**. No RTL fix or complete-game acceptance is claimed.

Closed runners, model pins and captures are under
`/home/yukidama/external/tmp/ventium-subjne-boundary.sT8Cc6/`.
`matrix-r2-results.json` is the passing matrix; the original matrix retains
20 trace-size-cap terminations and its checker-schema failures, not passes.
Its32 bulky owner logs are losslessly archived in `original-matrix-raw.tgz`;
each archived copy was hash-checked before removing the duplicate raw file.
`board-v0-audit.json` is the independent post-HLT regrade; the original board
controller's incorrect pre-OUT expectation remains recorded as exit 1.
