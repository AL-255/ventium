# FXCH throughput fixture repair — October 10

The old benchmark started with an empty x87 stack. Its first `FLD1; FXCH ST(1)`
therefore read an empty partner. Current shared-FP RTL correctly raised IE|SF
and substituted indefinite; pinned QEMU does not model that stack fault.
Masking nearly every x87 status/value record made this a poor throughput test.

One persistent `FLD1` before the loop, and one `FSTP ST(0)` afterward, repair
the fixture. The entire forty-iteration body is unchanged. Loop depth is 1–8,
both exchange operands are always valid, and final depth is zero. All
stack-fault/value masks are removed from this manifest; no comparator is
weakened. Invalid exchanges remain explicitly tested by `px87stk` and
`fp_shared/tb/tb_ven_fp_top.sv` (one/both empty, aliases, masked/unmasked).

On unchanged UV-fast model `b5453f16`, explicit AXI backend at zero additional
latency, the qualified private QEMU pre-exit observer gives:

| Fixture | Complete records | Unmasked functional comparison |
| --- | ---: | --- |
| Original | 924 | FAIL at first FXCH, record 2; terminal FSW 0041 |
| Balanced | 926 | PASS; no IE/SF anywhere, terminal FSW 0000 |

No trace records are dropped. The live post-INT terminal state and matching
instruction bytes are checked. No new RTL, model build, guest snapshot, STEP
mode or fallback mode is involved. The microbenchmark is mostly x87 and is
not itself a U/V throughput measurement.

The unchanged pinned cycle plugin was rerun for both fixtures and both modes.
Its cumulative final clocks change 907→910 (`fxchfree=1`) and 1187→1190 (off)
because of the two setup/teardown instructions. Manifest informational totals
now match those fresh traces, including all 926 retirements. The **CPI<=1.10
acceptance band is unchanged**. Legacy free-FXCH RTL timing is not requalified
by this functional check.

Evidence: `external/tmp/ventium-fxch-stack-fixture.bEpKDVXP/r4/closed.json`;
service invocation `cd982eb4fab943c9b905063a2256041e`. This repeats the earlier
private r3 check on the actual corrected repository source, requires identical
flat-image bytes, verifies that the manifest has no stack-fault masks and
checks its informational cycle totals against fresh plugin traces.
Both originals (including the pre-existing dirty manifest), binaries,
commands, input pins and native logs are retained. Pins stayed stable, all
children were reaped, and the bounded 512 MiB/zero-swap service closed normally.
Earlier r1/r2 diagnostic scripts failed on incorrect assumptions about the
optional trace `bytes` field (RTL omits it; QEMU records a 15-byte window).
They remain failed; r3 checks the actual QEMU prefix and flat-image bytes.

This is a **test-fixture correction, not a processor performance fix or a
green generic gate**. Canonical QEMU still omits the terminal record; x87 C1
and hard cycle-band failures remain open. Latest verified gameplay is
**0.49083588 total U+V IPC**, model `86731249`, clocks 1.2B–1.3B, predating
the unmeasured C1 repair. Full direct-memory CoreMark is 2.107843209/2.110905243
CM/MHz on `b5453f16`, not a cache-backed or FPGA result.
