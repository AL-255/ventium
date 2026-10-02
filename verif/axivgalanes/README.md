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
