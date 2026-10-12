# DMA generated-scope wiring repair — October 12

The current FPGA synthesis exposes a real platform bug: each `i8237.chan[i]`
uses `reset` and `flip_flop` before their module-level declarations. Vivado
creates **undriven local nets in each generate scope** (`Synth 8-3848`), rather
than connecting those ports to the later controller-level signals. Icarus also
reports implicit wires and reproduces the failure with four-state simulation.
A passing two-state full-PC simulation therefore did not qualify these wires.

## Fix and integration

Move both existing declarations immediately before the generate block. No FSM,
Boolean equation, port, register, transfer mode, pipeline stage or workload
special case is added. The intended controls now reach the channels. Because
the broken netlist could optimize away disconnected logic, **area and timing
equivalence to that broken netlist are not claimed**.

The fix is in the DMA section of the single canonical
[`ao486_MiSTer_ventium.patch`](../ao486-sim/patches/ao486_MiSTer_ventium.patch)
and in the working submodule. The submodule revision is unchanged; clean
checkout reproduction continues to use `ao486-sim/setup.sh`. The other dirty
PS/2 overlay edits are independent and are not part of this repair.

- Before: SHA-256 `39eb78423eca313120491301c248b82f58b8aaa89c39e5cd3a3224349e7a9ce1`.
- After: SHA-256 `262a8d0fcf788c0f7ea62e8e4734f7530446cea244a53c9aa466447cac10f2df`.
- [`prepare_dma_declaration_order.py`](prepare_dma_declaration_order.py)
  reproduces only this exact predecessor and rejects drift/reapplication.
- [`test_dma_declaration_order.py`](test_dma_declaration_order.py): **7 tests
  pass**, including clean canonical-DMA patch application/reversal, byte-exact
  transfer to the working platform, and unchanged non-declaration logic.

## Native regression evidence

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.
Both bounded native units closed with exit zero and unchanged input hashes.
Each runs original RTL, the complete fix, and two incomplete-fix controls.

| Test | Complete fix | Original / reset-only | Selector-only |
|---|---:|---|---|
| `dma-declaration-r1`, actual `i8237` | 74 checks pass | Unknown register word instead of `8123` | Stalled transfer remains active after software reset |
| `dma-system-declarations-r1`, actual complete `dma` wrapper | 82 checks pass | Same register failure | Same software-reset failure through real arbitration |

The controller test covers all four channels, distinct high/low address/count
bytes, shared byte-pointer behavior across channels, mid-pair pointer clearing,
and software abort in both transfer directions while memory is stalled.
The wrapper test covers both controllers and all seven physical device
channels, including cascade/mask arbitration, page registers and 16-bit-channel
address expansion. All stimulation is through public I/O, DMA request/grant
and memory ports; no hierarchical writes or forced internal state are used.
All six expected negative-control executions fail natively at the intended
check. The real cascade has no external channel-4 ACK pin; the wrapper test
excludes that unused vector bit, not any real channel.

Invocations: controller `84ff4547ff9c4d99972b69319d472716`;
wrapper `fd4c477e255442d28e7dab71fa76d02a`. The original compile warnings and
all failed control logs remain with the passing runs.

To repeat (use a new nonexistent output directory each time):

```sh
export TMPDIR=/home/yukidama/external/tmp
export PYTHONDONTWRITEBYTECODE=1
python3 fpga/test_dma_declaration_order.py -v
python3 fpga/run_dma_declaration_order.py --source /path/to/original/dma.v --out "$TMPDIR/dma-leaf-new"
python3 fpga/run_dma_system_declarations.py --source /path/to/original/dma.v --out "$TMPDIR/dma-wrapper-new"
```

The original source is retained in `dma-declaration-r1/parent/dma.v`. Each
driver requires its exact hash and derives its own fixed/mutated sources;
passing an already-fixed source deliberately fails instead of weakening the
negative controls. The two small Icarus tests need neither a C++ build nor a
second Vivado job.

## Remaining qualification

These tests prove register programming and **stalled-transfer abort**, not all
8237 transfer modes, normal transfer completion, audio or floppy compatibility.
There is no physical-board pass, complete standard-suite pass or measured
performance gain for this change yet. The current frozen FP-HIGH-VALID timing
run still contains the old DMA source and is deliberately untouched. The next
source-matched PC/FPGA candidate must carry this repair; check that Vivado no
longer reports these eight undriven channel controls, then run the required
full suite and physical Win95/Quake acceptance in UV+fast mode.

Current candidate gameplay IPC is unmeasured. The older simulated baseline is
**0.51030715 total U+V retirement events/cycle**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**; it does not qualify this platform change.
