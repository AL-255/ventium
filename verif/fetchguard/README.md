# `verif/fetchguard` — Instruction Fetch Boundary, `CS` Limit, and Overlength Probe Gate

## Scope and Architectural Invariants

`verif/fetchguard/` verifies the combinational instruction-fetch boundary, `CS`
segment-limit, overlength instruction (`> 15` bytes / `d_len == 0`), page-crossing
split-probe, and external-interrupt yield predicates in `rtl/core/core.sv`.

Rather than maintaining a duplicate reference model that could drift from production RTL,
`verif/fetchguard/run-gate.sh` extracts and compiles the **exact production right-hand-side
expressions** from `rtl/core/core.sv` into `tb_fetchguard.sv`:

- Extraction fails loudly if any expected signal assignment in `rtl/core/core.sv` is missing
  or ambiguous.
- Strict Verilator structural lint (`IMPLICIT`, `PINMISSING`, `UNDRIVEN`, `MULTIDRIVEN`,
  `LATCH`, `UNOPTFLAT`) fails on any unmodelled dependency.
- Source files, extracted RTL fragments, compiled binaries, and execution logs are SHA-256
  hash-bound before and after the run.

### Mandatory Subsystem Invariants

1. **Inclusive `CS` Segment-Limit Precision:**
   - A demand-fetch completion cursor pointing beyond an inclusive `CS.limit` is not an
     architectural memory access.
   - Each essential `1..4`-byte demand fetch beat checks both its first and last byte.
   - A legal instruction whose final byte lands exactly at `CS.limit` is accepted, whereas
     fetching the next byte faults `#GP(0)` prior to execution.
2. **Overlength `d_len == 0` Underflow Protection:**
   - An overlength decode (`d_len == 0`, instruction length `> 15` bytes) must never
     subtract `1` modulo 33 bits into a phantom `CS` segment-extent fault.
3. **External-Event Priority Over Provisional Probes:**
   - Overlength page probes yield cleanly to accepted debugger halt, `SMI#`, `NMI`, and
     `INTR` events rather than raising speculative page faults ahead of an architectural
     interrupt boundary.
4. **First-Overrun Page Attribution & Fragment Ownership:**
   - Split/overlength page probes name the endpoint page of the **first** atomically overrun
     instruction field rather than later unused fields, and shaping freezes during `S_WALK`
     under canonical fragment-engine ownership (`cur_lin_nat`).
5. **Fault & Held-Packet Suppression:**
   - Latched fetch-boundary faults and live in-page opcode-header faults suppress
     provisional decoded extents and overlength EA probes.
   - An already-admitted held pipeline memory packet (`pipe_mem_active_q`) is exempt from
     fetch handoff.

---

## Feature & Experiment Status

> **Physical Gameplay Baseline (`c0e3fe43`):** Verified physical Quake gameplay IPC on
> board-qualified image `c0e3fe43` (`main`, 161 defines, 40.000 MHz) is **`0.515778001`
> total U+V** (`0.397847833` primary/U-only; counters include `REP`-element retirement)
> across cycles **`28,696,827,616–32,989,404,795`**. Source-linked predicate checks do not
> measure gameplay IPC or substitute for whole-core/FPGA acceptance.

| Category | Features / Experiments | Status |
| --- | --- | --- |
| **Deployed in `c0e3fe43` (`main`)** | Production `core.sv` demand-fetch extent, `CS`-limit, overlength-probe, and held-packet predicates, paired with `u_ibuf_decode_stages` (`ibuf_d_len` and `d_fetch_*` isolated from `S_PIPE` `refdecode_ibuf` mux cones) to close 40.264 MHz post-route STA without weakening boundary safety. | **Board-qualified** (40.264 MHz post-route STA sign-off; CoreMark + Win95 + Quake `demo1` PASS) |
| **Rejected Timing Cuts (`experimental/uv-fast-ipc-apr`)** | October 2026 bus-address and demand-width timing derivatives: `DECODE_BUS_PAYLOAD` (regressed to `33.603 MHz` unplaced), `EARLY_BUS_PAYLOAD` (`34.050 MHz` unplaced), and `DEMAND_SIZE_PAYLOAD` (`35.876 MHz` unplaced). None reached the 40 MHz sign-off budget; `c0e3fe43` closed 40 MHz STA via `u_ibuf_decode_stages` isolation, front-end fanout replication, global retiming, and `opt_design -muxf_remap` instead. | **Rejected / not deployed** |

---

## Active Testbenches and Gate Scripts

| Script / Testbench | Role & Coverage |
| --- | --- |
| `run-gate.sh` + `tb_fetchguard.sv` | Primary source-extracted combinational predicate gate (`rtl/core/core.sv` extraction + strict Verilator lint + exhaustive boundary/limit/probe assertions inside the serialized `ipc_parallel32` build scope). |
| `run_probe_payload.py`, `run_probe_boundary_ab.py`, `run_probe_core_corpus.py` | Overlength page-probe endpoint attribution and bounded core-corpus equivalence checks. |
| `run_decode_bus_*.py`, `run_early_bus_*.py`, `run_demand_size_*.py` | Retained equivalence/timing-audit harnesses for the rejected October 2026 bus-address and demand-width cuts. |

---

## Safe Execution Guidelines

- Always allocate `--out` as a fresh, owned scratch directory under
  `/home/yukidama/external/tmp` with `TMPDIR=/home/yukidama/external/tmp` (verify mount and
  free space first; never fall back to `/` or home directories).
- Passing `run-gate.sh` verifies only extracted combinational predicates — it does **not**
  prove full-FSM event delivery, TLB authorization, or guest correctness. Always run `make
  verify` and `make verify-sys` after `rtl/core/` fetch/decode edits.

```bash
# Run the source-extracted fetch-guard predicate gate from the repository root:
export TMPDIR=/home/yukidama/external/tmp
out="$(mktemp -d /home/yukidama/external/tmp/ventium-fetchguard.XXXXXX)"
VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/fetchguard/run-gate.sh --out "$out"
```
