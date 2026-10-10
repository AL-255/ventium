# Zero-C1 and packed-decimal sign repairs — October 10, 2026

**Directed repairs pass; canonical gate and FPGA acceptance remain open.**
Latest verified gameplay remains **0.53765810 U+V event IPC**, older simulated
`bfb867f7`, cycles **4,500,065,237–4,600,065,237**. Neither new model below has
a gameplay measurement. These are correctness repairs, not measured Quake gains.

## Bugs and compact fixes

The [direct-load C1 repair](FLD_C1.md) missed three remaining problems:

1. Ordinary `FABS`, `FCHS` and `FXCH` retained stale C1.
2. Deferred `FBLD` completion also retained stale C1.
3. Both iterative and combinational packed-decimal conversion lost the sign
   of negative zero by converting through signed integer zero.

The P54 volume 3 manual, table 6-4 (printed 6-12, PDF page 151), defines ordinary
zero C1 for this class, with stack-fault overrides. FBLD (printed 25-89/90,
PDF pages 706/707) preserves the packed sign even for zero and converts exactly.
Source: `ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf`,
SHA-256 `63c27628292de539eb6ea9089404fe7b5d1fca9d292021a4493dce044e9aa988`.
Rendered pages are retained in external scratch `ventium-fbld-c1.3oY8umzw`.

[`prepare_zero_c1.py`](prepare_zero_c1.py), after the direct-load repair, clears
C1 at the existing accepted unary/exchange commit, **before** the stack-fault
override. Deferred FBLD clears it at its owned completion. Overflow never starts
that engine, so completion cannot erase overflow C1.

[`prepare_bcd_sign.py`](prepare_bcd_sign.py) converts the positive 18-digit
magnitude and attaches its original sign afterward. Legal magnitudes fit exactly
in int64 and extended precision. This removes a sign-dependent integer negation;
there is no new state, cycle, arithmetic unit or memory port.

Only the frozen candidate's `fp_shared/ven_fp_top.sv`, `rtl/fpu/ven_bcd_to_fp.sv`
and `fx_bcd_to_fx` package function change. The dirty checkout and running older
models remain intact. Recipes reject missing, duplicate and already-repaired
anchors. No guest-specific condition, snapshot dependency, pairing suppression
or global slow path is introduced.

## Verification and performance impact

[`run_zero_c1_observe.py`](run_zero_c1_observe.py) runs one unchanged ELF natively,
under pinned Pentium QEMU, and through actual UV-fast AXI RTL. FLDENV initializes
cases; FNSTSW/FNSAVE observe actual state, without debugger writes or trace edits.
The **3,906 cases** cover every TOP, both initial C1 values, masked/unmasked
invalid exceptions, sticky precision, signed zeros, all FXCH register positions
and empty-operand combinations, FBLD overflow and maximum legal magnitudes.
Additional FBLD cases cover all rounding modes and 24/53/64-bit precision control.
Full control, defined status, tags, TOP and nonempty values are checked; only
architecturally undefined condition codes and empty-slot payloads are excluded
from this new expected-state check. Native hardware is not P54 silicon; the
Intel manual supplies the architecture specification.

| Directed model | RTL failures | Native failures | QEMU disagreements | Clocks |
|---|---:|---:|---:|---:|
| `490afbdf`, load-only control | 834 | 0 | 3,170 | 6,078,483 |
| `863430a4`, zero-C1 fix | 86, all negative-zero value cases | 0 | 3,170 | 6,078,483 |
| `f74dd76b`, plus BCD sign fix | **0** | 0 | 3,170 | 6,078,483 |

All children exit zero. Each RTL run has **66 actual V retirements**, AXI backing
acknowledgements and zero delivered faults. QEMU disagreements remain recorded,
not waived into passing canonical goldens.

[`tb_bcd_sign.sv`](../../verif/fbld/tb_bcd_sign.sv) uses an independent decimal
positional-sum/normalization oracle. Seeds 1, 17 and 20260830 pass **120,045
checks** across iterative and combinational paths, including 36 negative-zero
discriminators against the old engine and 33 reset-position tests. Busy-time
operand/start changes do not replace ownership; busy/done match the old engine
each cycle. The earlier **1,216 direct-load cases** also still pass.

All **20 complete canonical cycle traces** match the load-only parent, record
for record. Unmodified `make verify` still exits **2 / FAIL**: **7/108** functional
passes and the same **12/19** scored cycle failures. No canonical masks, goldens
or cycle bands changed. Ten host tests pass:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=fp_shared/tb python3 -B -m unittest -v \
  test_fld_c1_observe test_zero_c1 test_bcd_sign
```

**Measured gain from these repairs: 0%** in the directed matrix, with no clocks
added or removed. No hardware-area or gameplay gain is claimed.

## Exact models and remaining acceptance

Evidence roots are under `/home/yukidama/external/tmp/`:

- `ventium-fbld-c1.3oY8umzw/{control,fixed}/result.json`: discriminating controls.
- `ventium-zero-c1-r2.YbZ65wgy/{audit.json,verify-closed.json,leaf/closed.json}`:
  independent recheck of 5,996 source pins, outputs, modes and complete cycle
  streams. Model `f74dd76ba78e2a09db09be0a69c58f08164b19f1d38782c6050492a34d27e9e5`;
  canonical supervisor invocation `c134f26faec44261ac62516c97018528`.
- `ventium-zero-c1-soc.FTbYSn0L/build-closed.json`: successful full-PC backport,
  model `2b4d7a48453fb8f901730d70b5731d9fb6a5459a83fc36f69241f441a7ab298e`.
  All 102 shared RTL/FP inputs match the directed candidate. The 154 simulation
  defines, posted-16 transport, 40 MHz setting and host disk-write flush remain
  unchanged. The platform's 98 structural warnings remain debt, not new waivers.

The candidate still needs its full standard suite and physical FPGA Quake/Win95
acceptance. Follow source export/synthesis in [the hardware record](../../fpga/CODE_PAYLOAD_EXPORT.md).
