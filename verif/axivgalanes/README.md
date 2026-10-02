# AXI/VGA read-lane qualification

This standalone test instantiates production `ven_axi2avalon.sv` and actual
ao486 `l2_cache.v`, with the VGA aperture enabled. It verifies accepted read
byte enables and actual VGA byte-read strobes under every preceding write
mask, all four byte lanes, aligned halfword/dword reads, and unaligned logical
MMIO spans decomposed into legal byte-exact pieces. Its endpoint records the
last enabled read address (architectural latch ownership); it does not claim
to implement VGA plane memory, write modes, scanout, or a Windows reference.

The native test fails on any mismatch. An expected red result is not a PASS.
The runner preserves both ordinary and deployed bridge/VGA-feature results,
input hashes, native exit status, and actual bounded resource receipts.
It never edits RTL, builds a processor, boots a guest, or accesses guest disks.
PINMISSING remains a hard error for new testbench and bridge ports. The
existing `romwrite_ao486_primitive.vlt` waiver applies only to the platform's
three primitive instances at `l2_cache.v:950-1060`.

After checking disk space, create a fresh owned directory under `verif/l1`
named `obj_dir_axivgalanes_*`, then run:

```sh
bash verif/axivgalanes/run-gate.sh --out /absolute/path/to/that/directory
```

For the post-repair positive run, use another fresh output directory and
set `AXIVGALANES_BRIDGE_ASSERT=1`. The same 192 legal read pieces run in
each profile; the production bridge's legal-shape assertions are then enabled.
The pre-repair run leaves that define off because the existing assertion
rejects legal narrow reads before their strobes can be observed.

`AXIVGALANES_HOLD=1` selects the separate `tb_axivgalanes_hold.sv` variant.
It changes AR address/size/length/burst/ID and idle WSTRB immediately after
each accepted AR, forces four Avalon wait cycles, and checks the captured
owner's address, read mask, response ID and downstream read side effects.
The original red/green test source is retained unchanged.

Existing WRAP coverage can be extended in `ao486-sim/ven/tb_axi2avalon.sv`
and `verif/l1/run-axi2avalon-wrap-gate.sh`; the original four-byte responder
does not establish byte-exact VGA read side effects. This independent test
does not modify that potentially user-owned work.

## Actual VGA planar storage regression

`tb_axivgalanes_planar.sv` additionally instantiates the production `vga.v`
and its real simulated plane RAMs. All plane/address initialization uses
ordinary AXI writes and VGA register I/O; there are no forced signals or
hierarchical RAM pokes. Distinct source bytes and an independent latch prime
make a missing or extra read observable in the subsequent stored bytes.

Each profile tests all16 preceding WSTRB values against four byte lanes, two
aligned halfwords and a dword:112 cases. For each case it checks source RDATA,
then both a mode0 masked write and a mode1 latch copy in allfour planes.
There are896 actual stored-plane checks and208 addressed source-byte checks,
including initialization readback. Requests and I/O changes wait for backend
completion, not merely an early AXI B response. Planar wide-store admission
and unexpected DDR traffic are rejected.

From the repository root, after checking available space:

```sh
task_planar_out="$(mktemp -d "$PWD/verif/l1/obj_dir_axivgalanes_planar_XXXXXXXX")"
bash verif/axivgalanes/run-planar-gate.sh --out "$task_planar_out"
```

The bounded runner enables bridge assertions by default and runs ordinary and
deployed-feature profiles, using32 build jobs in the existing16GiB/128-task
scope and a540-second total cap. Its300MiB leaf guard remains enforced.
After compilation closes, exactly the two owned generated PCH files per
profile are losslessly archived to adjacent `.recovery.gz` files. Their raw
and archive identities/hashes/sizes are retained in `pch-recovery.tsv`;
gzip integrity and expanded SHA are checked before removing only the exact
unused raw PCHs. Models, objects, source, logs and evidence are retained.
Rebuilding uses a fresh output leaf; any manual PCH recovery must target the
explicit missing raw path and verify the receipt's expanded hash.

The unchanged test fails on the pre-repair adapter even when source RDATA
looks correct:632 plane mismatches per profile, versus zero on the repair.
The old adapter's narrow-shape assertion must be disabled for this negative
control; otherwise it stops before the storage checks. An expected negative
control remains a failure, not a correctness PASS.

Scope is VGA storage/read-latch behavior through the production adapter and
L2 byte sequencer. It does not establish scanout, physical FPGA RAM collision
or clock-domain fidelity, Windows desktop correctness, or Quake acceptance.
