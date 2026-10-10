# Shared byte memory-CMP fast decode — October 10

Private, default-off proposal, **not standard-suite or FPGA acceptance**.
Latest verified gameplay is **0.46829233 U+V retirement-event IPC**, parent
`958f7ec4`, clocks **2,500,048,811–2,600,048,811**. All fourteen windows from
1,200,048,811 average **0.4782252957**, below 0.48. Audit:
`external/tmp/ventium-sfetch16-latest-r6.13etykyJ/audit.json`.
This candidate has no gameplay measurement. REP elements are retirement events,
not exact P54 macroinstruction IPC.

## Cause and general fix

The latest one-million-clock trace (`d37df58c`, 7M–8M) observes byte memory-
immediate CMP taking S_PIPE → S_DECODE → two S_LOAD clocks → S_EXEC, even on
a resident hit. The decoder already admits the equivalent `83 /7` dword CMP.

`prepare-byte-memory-cmp.py`, flag `VEN_FAST_BYTE_MEM_CMP`, shares that existing
address/segment/pairing grammar with `80 /7`. The existing byte-aware U ALU and
precise memory transaction perform the operation. No extra decoder instance,
ALU, memory port, address generator or workload-specific recognition is added.
Register `80` forms retain the original high-byte aliases/dependencies and
zero-extended immediate. Displacement+immediate remains unpairable, V admission
remains disabled for this memory form, and unsupported memory encodings and
16-bit address mode remain on the normal slow path. FPGA cost/timing is unmeasured.

## Directed verification

Leaf: `external/tmp/ventium-byte-memory-cmp.Id4X2qlF/leaf`.
Full 141-flag parent profile, six structural classes as hard errors:

- Original-vs-disabled and enabled checks cover **1,310,720 descriptors**:
  all ModR/M/SIB bytes, both mode inputs and unrelated opcode packets.
- **30,464 admitted memory cases** share the original dword address grammar.
  All **65,536 byte subtractions** check defined flags with an independent
  arithmetic oracle, not the production flag helper.
- Required-failure original reaches exact `BYTE-MEM-CMP-DECODE`, native 1.

Core: `external/tmp/ventium-byte-cmp-core.0JAvTgvU`, model **`ecc6fa47`**;
one-file/one-flag derivative of `068a1def`. Structural build and unique C++
object/header ownership pass. `matrix-r3/` / `fault-r3/` use original cold
paged BIOSes, two AXI latencies, both models, flat/relocated segments and all
32 code alignments. No records are trimmed or comparator masks changed.

- Normal **256 fixtures → 1,024 complete QEMU comparisons + 1,024 cycle runs**,
  66.16 s. Base/disp8/SIB-SS addressing and the last byte of a mapped page
  check exact-byte access; the following page stays absent. Among 512 matched
  totals, **336 improve, 176 equal, none regress**.
- Fault **192 fixtures → 768 complete QEMU comparisons + 768 cycle runs**,
  58.58 s. Each independently requires one nonpresent read #PF with error 0,
  precise saved PC/flags and CR2, repairs the PTE and retries successfully.
  **305 improve, 79 equal, none regress**. Actual paired-V retirement is
  required in both suites.
- Earlier `fault-smoke/` is a failed checker invocation (expected fault key
  incorrectly supplied as `14` instead of `(14,0)`). `fault-smoke-r2/` then
  exposed a fixture bug: the GDT relocates by 256 MiB, while the guest expected
  CR2 plus 16 MiB. Flat cases passed; relocated QEMU itself failed. The fixture
  expectation was corrected, not the processor or QEMU oracle. Earlier source
  copies/results remain. The final r3 normal and fault runs pin the corrected
  source and driver and pass in full.

## Matched bootable CoreMark

SoC: `external/tmp/ventium-byte-cmp-soc.XZHHrsqb`, model **`54651745`**,
one-file/one-flag derivative of `d37df58c`; private source closure/host header
ownership checked. The 98 inherited platform structural warnings are unchanged.
Same original ten-iteration disks, ROMs, full-P5 L1s, 256 KiB L2, posted-16
board transport and 40/40/80 MHz timebases:

| Seed | Parent ticks | Candidate ticks | Removed | Throughput gain |
| --- | ---: | ---: | ---: | ---: |
| Performance | 4,853,587 | **4,801,536** | 52,051 | **1.08405%** |
| Validation | 4,837,758 | **4,787,479** | 50,279 | **1.05022%** |

Short ratios **2.082666880 / 2.088782008 CM/MHz** are below 2.1 and **not
duration-valid scores**. Both five-CRC sets match QEMU; minimum-duration errors
remain. Native exits 0, actual CPU-3 affinity, stable media, reaped children and
no OOM are audited. `coremark/audit.json` rechecks 292 pins and successful
supervisor `806f94b7f9654e0bbc7a11a45462e4ee`.

Generic `make verify` is still **FAIL**, native 2, **7 PASS / 101 FAIL**, with
terminal/bounded-record and cycle-band failures retained. Supervisor:
`1de90974162a471eae68cbc32c9ed22e`; core `generic.log`. No fallback mode, golden
fabrication, trace truncation, mask or timing-band relaxation is used.
Inherited prefix/EX P54-resource qualification, duration-valid CoreMark, clean
Win95 desktop, full original Quake timedemo and routed/deployed FPGA remain open.
