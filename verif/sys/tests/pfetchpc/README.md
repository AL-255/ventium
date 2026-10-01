# Precise user instruction-fetch restart PC

This is a directed architectural regression, not Windows95/Quake acceptance.
The two-case BIOS makes ordinary user instruction-fetch faults through real
page tables and a CPL0 #PF/TSS stack. It uses no TB register pokes, snapshots,
guest patching, instruction skips, or synthetic golden records.

| Case | Required bytes | Exact #PF frame and CR2 |
| --- | --- | --- |
| First-opcode control | First byte at `0x00400000` is nonpresent after outer IRETD | EIP `0x00400000`, CS `0x1b`, CR2 `0x00400000`, error `4` |
| Slow-fetch precision | `C7 05 00 40 00 00 imm32` starts at `0x00401ffa`; its essential immediate is on nonpresent page `0x00402000` | EIP `0x00401ffa`, CS `0x1b`, CR2 `0x00402000`, error `4` |

The first case is a positive control and need not reproduce an S_FETCH bug.
The second instruction is not supported by the compact simple decoder. Its
essential page crossing tests the slow-fetch handoff without assuming that
incidental 16-byte lookahead should fault. A five-byte CALL fitting before a
nonpresent successor would instead test a separate overfetch question and is
deliberately absent here.

Each #PF handler reads and checks the exact saved EIP/CS/old SS:ESP, CR2, and
Pentium error code `4` (nonpresent user read, with no later-generation I/D bit).
The second handler proves the destination's seed and following-instruction
counter remain unchanged. It maps only the missing page, reloads CR3, and
IRETs without editing the saved EIP/CS. The restarted MOV and subsequent
counter must execute in order. Counter=1 proves resumed architectural flow;
it does not count physical bus writes of the idempotent MOV.

The grader retains every trace row, including legacy fault-delivery markers,
and requires actual debug-exit `133`, full frame readbacks, two exact ordered
canonical #PFs, normal closed I/O/retirement footers, and a complete unfiltered
architectural differential against pinned QEMU 8.2.2 `-cpu pentium`.

## Bounded validation

The commands below describe validation; actual closed run receipts, rather
than this document, establish a result. First inspect available space and
select a fresh private leaf under `/tmp`
or an existing root-filesystem build directory. The repo `tmp` symlink may
point at the full external volume; do not create a top-level home folder.

Build only this 64KiB BIOS, using an externally chosen fresh fixture directory:

```sh
df -h / /tmp
make -C verif/sys/tests/pfetchpc OUTDIR=/absolute/owned/fresh-fixtures
```

Run with an already-built, reviewed frozen simulator and its actual colocated
compile record. These arguments are deliberately not filled with a guessed
candidate or dynamically accepted hashes:

```sh
bash verif/sys/tests/pfetchpc/run-gate.sh \
  --tb /absolute/frozen-build/tb_ventium \
  --tb-sha256 REVIEWED_TB_SHA256 \
  --compile-sha256 REVIEWED_COMPILE_RECORD_SHA256 \
  --fixtures /absolute/owned/fresh-fixtures \
  --out /absolute/owned/new-gate-output --modes both --port 41697
```

`TB_BIN`, `TB_SHA256`, and `TB_COMPILE_SHA256` are optional explicit equivalents
of those three arguments; there is no fallback to building/clobbering the
canonical testbench. `--modes both` runs normal functional and `--cycle-func`
(cycle_mode=1 with full architectural state). Bare `--cycle` would emit only
cycle records and cannot substitute for either full-state differential.
The in-scope hard bound is 540 seconds (plus5-second cleanup); individual free
QEMU/golden/native/diff bounds are30/90/60/30 seconds. The runner never launches
Vivado, a full gate suite, or full-PC guests, and never reads a live guest disk.

A pre-fix failure is evidence only after inspecting its actual closed native
status and frame readbacks; a timeout or matching partial trace is not PASS.
The caller remains responsible for proving that the frozen build's source pins
cover the intended RTL candidate and for keeping ordinary differential gates
and the complete standard suite green after the fix.
