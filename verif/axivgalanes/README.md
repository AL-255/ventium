# AXI-to-Avalon Byte-Exact VGA Read-Lane Gates (`verif/axivgalanes/`)

`verif/axivgalanes/` verifies Ventium's non-cacheable MMIO byte-exactness invariant (`AGENTS.md`: *"Non-cacheable accesses are byte-exact; AXI models must honor ARSIZE/lane semantics rather than silently widening reads"*) across the production `ao486-sim/ven/ven_axi2avalon.sv` bridge, `ao486` `l2_cache.v`, and `vga.v` planar memory.

## 1. Read-Lane & Latch Ownership Gate (`run-gate.sh`)

`tb_axivgalanes.sv` (and `tb_axivgalanes_hold.sv` under `AXIVGALANES_HOLD=1`) instantiates `ven_axi2avalon.sv` + `l2_cache.v` with the VGA MMIO aperture (`0xA0000–0xBFFFF`) enabled:

- Sweeps **192 legal narrow read transactions** per profile across all 16 preceding `WSTRB` masks, all 4 byte lanes (`ARSIZE=0`), aligned halfwords (`ARSIZE=1`), dwords (`ARSIZE=2`), and unaligned spans decomposed into byte-exact pieces.
- Verifies exact accepted read byte enables and VGA read-latch address ownership (`AXIVGALANES_BRIDGE_ASSERT=1` enables the bridge's legal-shape assertions; `AXIVGALANES_HOLD=1` mutates `AR*`/idle `WSTRB` immediately after `ARREADY` across 4 Avalon wait cycles).
- `PINMISSING` and the structural lint classes remain hard errors (the narrow `romwrite_ao486_primitive.vlt` waiver covers only the three vendor primitives in `l2_cache.v:950-1060`).

```sh
export TMPDIR=/home/yukidama/external/tmp
out_dir=$(mktemp -d "$TMPDIR/obj_dir_axivgalanes_XXXXXX")
AXIVGALANES_BRIDGE_ASSERT=1 bash verif/axivgalanes/run-gate.sh --out "$out_dir"
```

## 2. Planar VGA Storage & Mode-0/Mode-1 Latch Gate (`run-planar-gate.sh`)

`tb_axivgalanes_planar.sv` adds production `vga.v` and its 4 simulated plane RAMs, driving all initialization and checks strictly through AXI transactions and VGA I/O registers (no hierarchical RAM pokes or forced signals):

- Tests all **16** preceding `WSTRB` values × `{4 byte lanes, 2 aligned halfwords, 1 dword}` = **112 cases** per profile (**896** stored-plane byte checks across VGA Write Mode 0 masked writes and Write Mode 1 32-bit latch copies + **208** source `RDATA` checks).
- Waits for true backend drain completion rather than posted AXI `B` acknowledgement, and rejects planar wide-store admission or stray DDR traffic.
- Discriminates cleanly: the pre-repair bridge produced `632` plane mismatches per profile even when `RDATA` appeared valid, whereas the production bridge passes with `0` mismatches across both ordinary and deployed-feature profiles.

```sh
export TMPDIR=/home/yukidama/external/tmp
planar_out=$(mktemp -d "$TMPDIR/obj_dir_axivgalanes_planar_XXXXXX")
bash verif/axivgalanes/run-planar-gate.sh --out "$planar_out"
```

> **Scope Note:** These leaf/seam gates verify VGA read-latch and planar byte-lane storage through `ven_axi2avalon` + `l2_cache` + `vga`. End-to-end physical VGA display + 128-RAMB36 frame capture are qualified on `main` release **`c0e3fe43`** (cold Windows 95 OSR2 GUI desktop + DOS Quake `demo1` `8.0 FPS`, **`0.515778001` total U+V gameplay IPC** across cycles `28,696,827,616–32,989,404,795`).
