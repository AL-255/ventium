# Shared load C1 repair — October 10, 2026

**Directed repair passes; not standard-suite or deployment acceptance.**
Latest verified gameplay remains the older `bfb867f7`: **0.53765810 U+V
event IPC**, clocks 4,500,065,237–4,600,065,237; its complete recorded 3.4B
window averages 0.496534277. The load-repaired candidate has no gameplay
measurement or qualified CoreMark score.

## Finding and compact fix

The first-divergence-only x87 audit missed real errors **after** correctly
rounded arithmetic. Inspecting all 94 nonterminal unmasked FSW divergences
with the passive native observer found four where RTL was wrong:
`tx_chain` records 15/17 and `tx_unifdiv` records 5/6. All are FLD instructions
retaining stale C1. Native hardware and QEMU both clear it at these sites.
The other 90 disputed-bit observations agree with RTL; this does not qualify
all canonical differences, GPR propagation or the terminal record.

The 1995 P54C manual, volume 3, **table 6-4 (6-12)** and **FLD (25-110)**
define C1 as zero for ordinary loads, while stack faults report overflow or
underflow. PDF pages 151 and 727 were rendered and inspected using the PDF
skill; source SHA-256 is
`63c27628292de539eb6ea9089404fe7b5d1fca9d292021a4493dce044e9aa988`.
Local source: `ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf`.

[`prepare_fld_c1.py`](prepare_fld_c1.py) adds a C1 clear under the existing
accepted direct `c_push` predicate, **before** the existing stack-fault
override. Deferred arithmetic/transcendental pushes keep their own status
ownership. There is no new state, latency stage, arithmetic unit or RAM port.
The change is confined to `fp_shared/ven_fp_top.sv` in a private, frozen
derivative; the dirty checkout and already-running full-PC images are not
overwritten. The legacy writeback backend and deferred FBLD are not repaired
or qualified by this change.

## Regression and exact candidate

[`run_fld_c1_observe.py`](run_fld_c1_observe.py) executes an unchanged ISA
fixture natively, under pinned QEMU and through real AXI UV-fast RTL:

- 1,216 cases: FLD m32/m64/m80/ST0, FILD m16/m32/m64, FLD1/FLDZ;
  every TOP, both initial C1 values, masked/unmasked invalid exceptions,
  clean/sticky precision status, ordinary load/overflow and register underflow.
- Actual FLDENV seeds the test condition; FNSTSW/FNSAVE observe actual state.
  No debugger state changes, guest patches, trace normalization or canonical
  mask changes. Only architecturally undefined C0/C2/C3 and empty-slot values
  are excluded from the new independent expected-state check.
- All defined status, control word, tags, TOP and nonempty register values are
  checked. Unmasked stack faults must not push; masked faults must materialize
  indefinite; overflow must retain C1=1. Sixty-six real V retirements and AXI
  backing acknowledgements are required.

| Model | Native mismatches | RTL mismatches | Pinned-QEMU disagreements | Clocks |
|---|---:|---:|---:|---:|
| `1139570b` control | 0 | 288 | 928 | 1,869,470 |
| `490afbdf` repaired | 0 | 0 | 928 | 1,869,470 |

No latency regression in this directed test, and no throughput gain is claimed.
The QEMU differences remain visible, not promoted into passing canonical goldens.
Four host recipe/expectation tests also pass.

All roots are under `/home/yukidama/external/tmp/`:

- Native full-divergence evidence and control: `ventium-preexit-fsw-all.Jbs7ZZ8o`.
- Repaired core: `ventium-fld-c1-core.Vr1KAdle`; build closes native 0 in
  20.01 seconds, 32 bounded compiler jobs, unchanged source pins/defines,
  matching private harness/header. Exact model is
  `490afbdf8a0c540f864da16378c6ad8bb17a2188a552b73175418b37dc9177dd`.
- `load-directed/result.json` retains every actual/expected state and native
  exit. Unchanged canonical `make verify` closes native 2 / FAIL: 7/108
  functional passes and the same 12/19 scored cycle failures. Independent
  `audit.json` rechecks 5,590 input pins and all 20 complete cycle-record
  streams, which are identical to the parent. The retained verification
  invocation is `1d22f1b3586443679b6a7f5be92df82e`. Neither the directed
  repair nor unchanged cycles waive this red gate.

Finite exact load data and stack exceptions are covered here; numeric
NaN/denormal exception conversion, memory-fault ordering and every other x87
instruction are not certified by this matrix. The ongoing `4fb1bdae` cold
standard suite predates this repair. A full-PC backport and its standard suite
are still required before claiming the repaired candidate complete.

Follow-up: [zero-C1 and packed-decimal sign repairs](ZERO_C1_BCD_SIGN.md) cover
the previously excluded deferred FBLD completion and unary/exchange operations.
They retain this load regression; their newer full-PC model is separately
identified and is not qualified by the older model's results.
