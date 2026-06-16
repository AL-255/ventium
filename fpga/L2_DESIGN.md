# ven_l2 — UltraRAM L2 cache controller (design blueprint)

A large, write-back, set-associative L2 that turns the KV260's otherwise-idle
**64 UltraRAM blocks (18 Mb)** into a working set that hides PS-DDR4 latency. Sits
between the L1's word-granular backing port and the PS-DDR AXI master. **Standalone
as of this drop** — synthesizable + unit-checkable, but nothing in the core/SoC
instantiates it yet (per the task: "leave it standalone and don't wire it up").
Cross-ref `fpga/L1_AXI_DESIGN.md` (the port it splices into) and the RTL header in
`rtl/mem/ven_l2.sv` (the authoritative spec).

## 0. Why an L2, and why now
The L1 (`ven_l1d`, 8 KB) acks a hit in the same clock but a miss is a full DDR
round-trip over AXI (~50–100 core clocks via `ven_axi_master` → SmartConnect → DDR).
The part has 64 URAM288 (4096×72 = 288 Kb each) that no other block uses. A 2 MiB L2
across all of them hides DDR latency three ways:
1. **Capacity** — 2 MiB vs 8 KB (256×) collapses the miss rate; most L1 misses now
   hit on-chip and never touch DDR.
2. **On-chip hit latency** — an L2 hit returns in a handful of cycles (tag → data,
   both URAM/BRAM) vs ~50–100 for DDR.
3. **Write-back absorption** — the L1 is write-*through*; the L2 absorbs that store
   stream and writes a dirty line to DDR once, on eviction, not per store.

## 1. The seam it splices into (drop-in, zero glue)
The subsystem already speaks ONE word-granular *backing port* that `ven_l1d` drives
and `ven_axi_master` consumes:

```
core mem_* ─► ven_l1d ─(backing port)─► ven_axi_master ─► AXI4 ─► PS-DDR
```

`ven_l2` is a drop-in for that wire. It is a **slave** of the backing protocol on its
upstream port (`u_*`, so `ven_l1d`'s master plugs straight in) and a **master** of the
same protocol on its downstream port (`d_*`, so `ven_axi_master`'s slave plugs straight
in):

```
ven_l1d.m_* ─► [u_*] ven_l2 [d_*] ─► ven_axi_master.m_*
```

Integration later is a pure rewire — **no change** to `ven_l1d` or `ven_axi_master`.

**Backing-port contract** (matched on both ports):
* **READ / fill** — hold `req=1,we=0`, walk 8 ascending line-aligned word addresses,
  one `ack`(+`rdata`) per word, ascending, no per-beat valid, no backpressure; base
  latched from the first address. `ven_l1d` only ever reads a full 32-byte line.
* **WRITE** — one transaction, `we=1`, a **byte** address + lane-0-based 4-bit `wstrb`
  over bytes `[addr[4:0]..addr[4:0]+3]`, which may straddle a word **and** the line
  end; exactly one `ack` when durable.
* **single outstanding** — the L1 fill/write is blocking, so the L2 sees one upstream
  transaction at a time. Hence **no MSHR / hit-under-miss** — the latency hiding is
  capacity + fast hits + write-back, not request-level parallelism. (Hit-under-miss
  only matters once independent I/D requesters share the L2 → an integration-time
  arbiter concern.)

## 2. Geometry → exact URAM tiling
Defaults: **2 MiB, 32-byte line, 8-way**. 32 B == the L1 fill granularity == the
oracle `p5trace` line, so cache behaviour stays consistent and one L2 miss is exactly
one downstream fill.

| Quantity | Value |
|---|---|
| lines | 2 MiB / 32 B = 65536 |
| DATA array | 65536 deep × **256 bits** wide |
| **URAM tiling** | 256 b = **4 URAM-wide** (64 data bits/tile; each URAM288 word is 72 b → 4×8 = 32 spare parity bits/word) × 65536/4096 = **16 URAM-deep** = **64 URAM288** |
| sets | 65536 / 8 = 8192 (index = `addr[17:5]`) |
| tag | `addr[31:18]` = 14 b |
| META array | 8192 deep × 135 b BRAM: per set = 8×{valid,dirty,tag14} + 7 PLRU bits ≈ **1.1 Mb** |

This is a perfect column fit: Vivado cascades URAM up to 16-high, so the data array maps
to **4 columns × 16 = exactly the 64 URAM288** on `xck26`. The 32 spare parity bits/word
(11.1%) are **reserved for a SECDED ECC** follow-on (a SECDED(265,256) code needs 9
check bits, which fits comfortably); the design is sized to the full 18 Mb. Confirm with
`vivado -mode batch -source fpga/scripts/probe_l2_uram.tcl` (expects `URAM288=64`).

Capacity / line / associativity are parameters; the unit gates instantiate a tiny
1 KiB/2-way L2 so init + evictions simulate fast.

## 3. Microarchitecture
* **Policy** — write-back, write-allocate. Store hit → RMW the resident line in place +
  mark dirty (no DDR). Store miss → fill then merge (no DDR write until eviction). Clean
  victim dropped; dirty victim written back (8 word writes) before its slot is refilled.
* **Hit path** — serial **TAG → DATA** (read the set's packed tags, compare 8 ways → way;
  then read that way's 256-bit line from URAM, `RAM_RD_LAT`=2 pipeline). A read hit
  streams 8 words upstream; a write hit byte-writes the store into the line in place.
* **Read-miss path — FORWARD-DURING-FILL.** Each DDR word is handed straight to the L1
  (`u_ack=d_ack`, `u_rdata=d_rdata`) as it arrives AND captured into the fill buffer, so
  the L2 adds ≈0 latency over a bare DDR fill while still populating itself.
* **Replacement** — tree-PLRU, but an INVALID way is always preferred (fill cold
  capacity before evicting).
* **Writes that straddle a line** — decomposed into line `L` (`be0/wd0`) and, if the
  store spills past byte 31, line `L+1` (`be1/wd1`, low ≤3 bytes), run as two sequential
  line transactions (phase 0 then phase 1), one upstream ack after both. Mirrors the
  per-word split `ven_axi_master` does today, but at line granularity.
* **INIT** — URAM/BRAM have no global reset, so an init FSM walks all sets clearing
  valid bits (`L2_SETS` clocks) after reset; `ready` is low until done and upstream
  requests are ignored (not acked) during init.

### FSM (states in `state_e`)
`S_INIT` → `S_IDLE` → `S_LK0`/`S_LK1` (tag lookup) → branch:
* read hit: `S_RHIT_WAIT` → `S_STREAM` (8 words) → `S_IDLE`
* write hit: byte-write + dirty in `S_LK1` → `S_WDONE` → (phase 1?) → `S_WACK` → `S_IDLE`
* miss: (`S_EV_WAIT` → `S_WB` if dirty victim) → `S_FILL` → `S_MERGE` →
  read: `S_IDLE` (already streamed) / write: `S_WDONE` → (phase 1?) → `S_WACK`

A stuck DDR is handled **out-of-band**, not by the L2. `ven_axi_master`'s
per-transaction watchdog raises its own sticky `bus_err` (it does **not** synthesize an
ack — it holds AXI VALID), and that `bus_err` wires straight to the core's
`bus_err`→`S_HALT` override — it is **not** part of the backing-port wire the L2 splices
into. The core halts and the PS resets the whole PL, so the L2 wedging in `S_FILL`/`S_WB`
is moot (torn down by the reset, not by unwinding its own FSM). A self-contained L2
watchdog + fault re-export is a possible hardening once the L2 is actually wired
(intentionally out of scope for this standalone drop).

## 4. Verification
Two standalone Verilator gates (run from repo root):

* `verif/l1/run-l2-gate.sh` (`tb_l2`) — focused L2 logic against a synthetic DDR with a
  configurable per-word latency and access counters: cold fill (forward-during-fill),
  L2 hit (**0 DDR reads**), write-back (**0 DDR writes** on store hit / write-allocate),
  clean vs dirty eviction (byte-correct writeback), sub-word / unaligned / cross-line
  straddle stores, latency tolerance.
* `verif/l1/run-l2-axi-gate.sh` (`tb_l2_axi`) — **end-to-end through the REAL
  `ven_axi_master` + `axi_slave_bfm`** (RD/WR latency + a mid-burst RVALID bubble +
  the 32→40-bit remap). Proves the L2's downstream master is a drop-in: fills become one
  **INCR8** burst, dirty writebacks become single-beat writes, an L2 hit issues **no AR**,
  write-back issues **no AW**, no `bus_err`.

`verilator --lint-only -Wall` is clean. Bound SVA in the RTL check the live-protocol
invariants (downstream read base 32 B-aligned, no R/W overlap, `u_ack` legal-state only,
data array never read+written same cycle).

## 5. Follow-on (intentionally not in this standalone drop)
SECDED ECC over the 32 spare URAM parity bits · a writeback **buffer** so a dirty eviction
doesn't serialize in front of the fill · **burst** (vs per-word) dirty writeback ·
a next-line / stride **prefetcher** (needs a low-priority abortable channel → the I/D
arbiter) · a proper writeback-**flush** walker for cosim coherence (a bulk invalidate
would DROP dirty data, so flush is deliberately omitted, not done wrong) · MSHR /
hit-under-miss once there are multiple requesters · wiring it into the core behind
`ven_l1d` (an `IC/DC` backing arbiter + a `bus_mode` to route through the L2).
