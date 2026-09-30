# RTL ↔ testbench interface (v1)

How the Verilator C++ testbench (`verif/tb/`) drives and observes the RTL core
(`rtl/`). Pinned so the RTL author and the testbench author can work
independently. See also [`trace-format.md`](trace-format.md).

## 1. Top module

`rtl/ventium_top.sv`, module `ventium_top`, ports:

| port | dir | width | meaning |
|---|---|---|---|
| `clk`   | in  | 1  | core clock, rising-edge |
| `rst_n` | in  | 1  | active-low synchronous reset; held low ≥1 cycle at start |
| `mem_*` | various | — | bus-functional-model port group (see §3) |

All architectural observation happens through the **DPI retire callback** (§2),
*not* through output ports — this keeps the top port list stable as the core
grows and avoids exposing internal register files as ports.

## 2. DPI retire callback (the observation contract)

The RTL **imports** one DPI-C function and **calls it once per retired
instruction**, in architectural order, with that instruction's fetch PC and the
**post-commit** architectural state (matching `trace-format.md` §2.2):

```systemverilog
import "DPI-C" context function void vtm_retire(
    input longint unsigned n,        // retire seq, 0-based, monotonic
    input int      unsigned pc,      // fetch vaddr of retired insn
    input int      unsigned eflags,
    input int      unsigned eax, input int unsigned ecx,
    input int      unsigned edx, input int unsigned ebx,
    input int      unsigned esp, input int unsigned ebp,
    input int      unsigned esi, input int unsigned edi,
    input shortint unsigned cs,  input shortint unsigned ss,
    input shortint unsigned ds,  input shortint unsigned es,
    input shortint unsigned fs,  input shortint unsigned gs);
```

- The testbench **implements** `vtm_retire` (C++ linkage `extern "C"`) and emits
  one func-mode `.vtrace` line per call.
- `n` is the core's own retire counter (starts at 0, +1 per retired insn).
- The core calls this from a single always_ff retire point; pairing (two retires
  in one cycle, M4+) means two calls in the same clock with consecutive `n`.
- **x87** (M3+) uses a second optional import `vtm_retire_x87(...)` called
  immediately after `vtm_retire` for FP-affecting instructions — see §2.1.
- A `--no-dpi` Verilator define lets the core compile without the import for
  standalone lint.

### 2.1 x87 retire callback (M3+)

Experimental `VEN_FP_ASYNC` builds additionally import
`vtm_fp_async_event(event_kind, owner)`: kind 0 begins the pending FP record
immediately before its ordinary retirement callbacks; kind 1 completes it
after `vtm_retire_x87(owner, ...)` supplies the actual committed result.
Only final functional x87 record formatting is deferred; live counters,
diagnostics, integer state and cycle observations are not delayed. A second
owner, missing completion snapshot or unfinished trace is an error. This
default-off integration is not yet behaviorally qualified; see
`verif/issue_uv/FP_INTEGER_OVERLAP.md` for its acceptance gates and limitations.
The full-PC `ao486-sim/ven/vtm_dpi.cpp` observer does not format architectural
x87 traces and leaves both valid events inert, just like its x87 snapshot
callback. It must not delay live retirement counters or substitute FP results.
Architectural x87 equivalence is checked by the differential testbench above,
not by the full-PC observer.

The experimental arithmetic-stream observer additionally accepts event kind 2
to begin an ordered multi-owner record. It supports at most four outstanding
owners, consumes completions strictly oldest-first, and applies each RTL-supplied
completion state only to that owner's record and following integer records up
to the next FP owner. Kind 0 retains the original single-owner rejection; the
two begin modes cannot be mixed while work is pending. This is formatter-only
bookkeeping: it neither supplies FP results nor delays live clocks, retire
counters, syscalls or architectural debug observations. The full-PC observer
accepts kind 2 statelessly. The experimental `VEN_FP_ASYNC_STREAM` core generates
these events and retains an ordered four-entry DPI owner FIFO. This requires
the shared arithmetic stream and checked early-command path; it is not a default
configuration or a claim of full-system compatibility.

`VEN_FP_FXCH_QUEUE` adds one ordered FXCH admission slot in front of the shared
FPU and requires `VEN_FP_ASYNC_STREAM` in the core. A busy-leaf, masked FXCH
can be accepted into that slot without changing the architectural stack yet.
It generates the same kind-2 deferred owner as an asynchronous arithmetic
command, and completes from the actual ordered leaf response. In particular,
`cmd_accept_retire` is false for a queued exchange and remains false when that
queued command is later dispatched internally. An idle, immediately executed
exchange retains the original immediate-retirement contract. No synthetic FP
snapshot or delayed live retirement counter is used. Interrupt/fault/debug drain
gates remain in force. Leaf ordering/reset/metadata tests and the core QEMU
overlap/INT3 gates are documented in `verif/issue_uv/FP_INTEGER_OVERLAP.md`;
the profile remains opt-in pending full-system qualification.

For x87 floating-point instructions the core calls `vtm_retire(...)` (integer
state, unchanged) **and**, on the *same retirement* (same `n`), a second DPI-C
import `vtm_retire_x87(...)` carrying the **post-commit x87 state**. The
testbench buffers the x87 state keyed by `n`; the paired `vtm_retire` then emits
**one** func record carrying both halves, and the RTL trace header declares
`x87:true` (the testbench `--x87` flag). Declared in `ventium_pkg.sv`, guarded
by `VTM_NO_DPI` like `vtm_retire`.

```systemverilog
import "DPI-C" context function void vtm_retire_x87(
    input longint  unsigned n,         // SAME retire seq as the paired vtm_retire
    input int      unsigned fctrl,     // control word (16-bit value, 32b slot)
    input int      unsigned fstat,     // status  word (16-bit value, 32b slot)
    input int      unsigned ftag,      // tag     word (16-bit value, 32b slot)
    input longint  unsigned st0_lo, input shortint unsigned st0_hi,  // st0
    input longint  unsigned st1_lo, input shortint unsigned st1_hi,  // st1
    ... st2..st7 ...);                                               // st2..st7
```

**80-bit passing convention.** Each `st(i)` is the canonical `floatx80` value
split into two operands:

| operand | type | bits | meaning |
|---|---|---|---|
| `st<i>_lo` | `longint unsigned` | [63:0]  | mantissa (the low 64 bits) |
| `st<i>_hi` | `shortint unsigned`| [79:64] | sign \| exponent (the high 16 bits) |

so the reassembled 80-bit register is `{st<i>_hi, st<i>_lo}` — exactly the
encoding `gen_trace.py` emits (sign\|exp in [79:64], mantissa in [63:0]). The
testbench formats `st<i>` as the 20-hex-digit string `0x%04x%016llx` =
`hi`·2⁶⁴ + `lo`, so the RTL and QEMU hex strings compare directly
(`trace-format.md` §2.2, `tracefmt.h80`).

**Control words.** `fctrl`/`fstat`/`ftag` are 16-bit architectural fields passed
in `int unsigned` slots (mirroring how `vtm_retire` passes the 16-bit selectors);
the testbench masks to 16 bits and formats `0x%04x`.

**Untracked pointer fields.** `fop`/`fiseg`/`fioff`/`foseg`/`fooff` are **not**
passed: QEMU linux-user reports them as 0, so the testbench always emits 0 for
them (`trace-format.md` §2.2, `m3-fpu-spec.md`).

**Convention rules.**
- The core calls `vtm_retire_x87(n, ...)` with the *same* `n` it passes to the
  paired `vtm_retire`, with the **post-commit** stack/tag/status state.
- It must call this for any retirement that touches x87 state. If the core does
  **not** call it for a retirement while the testbench is in `--x87` mode, the
  testbench emits **zeros** for the x87 fields (the record stays well-formed).
- The comparator only compares x87 fields when **both** trace headers declare
  `x87:true`; integer programs keep `x87:false` and are unaffected.

## 3. Bus-functional model (memory port group)

M0 is L1-only with a flat backing memory owned by the testbench. The core's bus
port is deliberately minimal at M0 and grows toward the real 64-bit P5 bus
(`ADS#/BRDY#/NA#/KEN#/CACHE#/...`, see PLAN §2) at M5. M0 contract:

| port | dir | width | meaning |
|---|---|---|---|
| `mem_req`   | out | 1  | request valid |
| `mem_we`    | out | 1  | 1=write, 0=read |
| `mem_addr`  | out | 32 | byte address |
| `mem_wdata` | out | 32 | write data |
| `mem_wstrb` | out | 4  | byte enables (writes) |
| `mem_rdata` | in  | 32 | read data (valid when `mem_ack`) |
| `mem_ack`   | in  | 1  | single-beat handshake (combinational-OK at M0) |

The testbench preloads the flat memory from the test image (§4) and services
`mem_req` each cycle. This is a placeholder protocol; M2 adds instruction fetch
width/lines, M5 replaces it with the modeled P5 bus FSM.

### Backing memory replay policy

`ventium_l1_axi` and `ven_axi_master` expose `LINE_REPLAY` (default 1).
This integration policy controls the historical stale-first-burst workaround:
1 discards a priming cache-line burst; 0 delivers the first burst. It does not
change `NARROW_REPLAY_SAFE`, narrow access widths, posted-write ordering,
response-ID checks or fatal error handling. Disable it only for a qualified
backend; HP/HPC deployments retain replay. `ventium_top.AXI_LINE_REPLAY` passes
this policy through. The ao486 shim's opt-in `VEN_AO486_SINGLE_FILL` sets it to
zero for that backend only; it is not a default or gameplay-qualified profile.
`VEN_SINGLE_FILL` remains a separate unsafe diagnostic
override. `verif/l1/run-axi-line-replay-gate.sh` tests both healthy policies and
requires the stale-response negative controls to fail visibly.

### Cached-store effect policy

`VEN_L1D_STORE_POLICY` adds an optional platform advisory, separate from memory
access permission. `ventium_top.store_policy_addr` exposes the actual physical
U request address; `store_policy_update_mask[3:0]` controls whether each
producer-relative byte may update a resident cached copy. The independently
qualified paired V store has its own address and mask. A mask bit applies only
when the corresponding original write strobe is active.

A disabled active byte does **not** drop, narrow or fault the bus write, change
its acknowledgement, or suppress write-buffer admission/combining. It suppresses
that cached byte update and invalidates the touched resident physical tag on
the accepted edge. The next read misses, drains ordered older writes and refills
the actual backing bytes. Both packed and banked arrays follow this rule, as do
crossing U writes and independently acknowledged V stores. The policy must not
depend on ACK or request shaping; query addresses are independent outputs.
Without the define, the previous interface and update path are unchanged.

The ao486 shim conservatively disables cached updates for effective backend
bytes `C0000–FFFFF`, applying the existing 28-bit address fold and A20 gate
**per byte**. These windows may discard ROM writes or become writable through
UMA/shared-folder policy. Sampling that deferred policy at local posted ACK
would be unsafe: an older queued enable can reach the backend first. Targeted
invalidation handles either outcome without guessing, changing read cacheability,
globally flushing the cache, or disabling ordinary RAM updates. The original
ao486 backend remains the authority on the write's actual memory effect.

## 4. Image loading

The testbench loads a flat memory image and a load address from the test
manifest (`verif/tests/<name>/manifest.json`: fields `image` = path to a raw
binary blob, `load_addr`, `entry`). `verif/tests/` provides a helper that
extracts the loadable bytes of the test ELF into a flat blob. Reset vector / EIP
init = `entry`.

## 5. M0 NOP-stub behaviour

At M0 `ventium_top` need not decode/execute real x86. It must:
1. come out of reset cleanly,
2. retire a short, deterministic canned sequence (e.g. N "instructions"),
   calling `vtm_retire` with monotonic `n` and stub state (e.g. `pc=entry+seq*…`,
   zeroed regs), and
3. assert an end-of-trace condition (finite sequence, then idle) so the TB stops.

This proves the clock/reset/DPI/trace path end-to-end. Real decode/execute lands
at M1.
