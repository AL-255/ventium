# Isolated translation-path physical probe

This is **not** a full CPU build, bitstream, FPGA acceptance test or CPU Fmax.
It compares the actual 16-set/four-way P54-large parent DTLB with no cut, the
one-entry cut, and `ven_fe_dtlb`'s eight-entry cut. Parent U permissions and
the independent V translation remain live. Input and output register boundaries
are identical. The one-entry variant is a cost control, not an acceptable
throughput repair.

The Oct 8 run is recorded in
[the translation-cut audit](../../../docs/UV_FAST_TRANSLATION_CUT_2026-10-08.md).
It used this exact probe/Tcl/driver in a private source-pinned directory.

Reproduce only after checking external ext4, disk and RAM availability, and
that no existing Vivado or heavyweight build is active:

```sh
task_probe=$(mktemp -d /home/yukidama/external/tmp/ventium-fe8-physical-leaf.XXXXXX)
cp verif/fe_pipe/physical/{tlb_cut_probe.sv,inspect_pc_paths.tcl,run_synth.py} "$task_probe/"
cp rtl/mem/tlb_assoc.sv verif/fe_pipe/prototype/ven_fe_dtlb.sv "$task_probe/"
TMPDIR="$task_probe" python3 -B "$task_probe/run_synth.py"
```

The driver hashes sources, requires fresh output, launches through the exclusive
Vivado guard, uses one internal tool worker, caps RAM at 8 GiB with no swap,
stops early at 7 GiB, and enforces a 600-second limit for all three leaves.
It records the owned scope, sampled peak usage, final native exit and input pins.
No production project, checkpoint, mode, clock or board is changed.

`native-output/` contains three isolated routed checkpoints and area, route,
setup/hold and targeted register-to-register timing reports. Ports deliberately
lack I/O timing/dedicated partition pin constraints: external/clock routes and
whole-CPU congestion are **not** modeled. Do not interpret OOC port warnings as
board acceptance or report the leaf's clock-equivalent number as CPU frequency.
The query-to-physical, query-to-permission, V-query and worst internal paths
must all be considered; a shorter PFN path alone cannot qualify the core.
