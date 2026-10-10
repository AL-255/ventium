# Memory FST round-direction repair — October 10

**Directed repair passes; generic differential gate remains FAIL.**
Latest verified gameplay is **0.49761630 total U+V retirement-event IPC**,
`958f7ec4`, clocks 1,300,048,811–1,400,048,811. Both consecutive 100M windows
beginning 1,200,048,811 average **0.497514935**. This additional FPU repair has
no gameplay measurement. Full direct-memory CoreMark remains **2.107843209 / 2.110905243**
on `b5453f16`, not cache/DDR/FPGA performance.

## Reproduced defect and authority

The shared miscellaneous converter returns a rounded memory value and exception
flags, but no round-direction bit. Its architectural owner consequently retains
old C1 on FST/FSTP m32/m64/m80, including stores which actually round the other
way and exact extended stores which should clear it.

The primary P54 reference is the local **241430-004 Pentium Family Developer's
Manual, Volume 3**, printed pages **6-12, 7-27 and 25-138**. Table 6-4 names C1
as round-up for narrow stores when PE is set, and explicitly names extended-real
FSTP as zero-or-stack-fault. The modern
[Intel instruction reference](https://cdrdv2-public.intel.com/774492/325383-sdm-vol-2abcd.pdf)
also describes FST/FSTP narrowing and C1. The local primary PDF SHA256 is
`63c27628292de539eb6ea9089404fe7b5d1fca9d292021a4493dce044e9aa988`.

`run_fst_memory_observe.py` executes **2,352 cases** using ordinary FLD/FLDENV,
actual memory stores and FNSAVE. It covers both signs, all four RC values,
both prior C1 values, pop/no-pop where encodable, nearest-even tie directions,
normal/subnormal boundaries, gradual underflow, significand carry and overflow.
Memory sentinels check store width. Tags, TOP, unchanged non-popped ST0, control,
exception flags and output values are checked. These tests use masked exceptions
and PC64; they do not claim unmasked faults, NaNs or complete memory-fault coverage.

An independent integer/rational calculation agrees with native x87 for every
observed field. Native hardware is **not claimed to be original P54 silicon**.
The existing `dbd4330b` UV-fast model and pinned QEMU each have **1,176 C1-only
differences**, and zero value/exception-flag differences:

| Case class | RTL C1 differences |
| --- | ---: |
| Inexact m32 stores, PE set | 496 |
| Inexact m64 stores, PE set | 496 |
| Extended m80 stores, documented zero C1 | 24 |
| Exact m32/m64, native clears C1 | 160 |

The first **1,016** directly exercise the cited P54 flag requirements. The
last 160 additionally test native exact-store behavior; the manual's conditional
round-up description alone is not proof that every one is an architectural
violation. No canonical mask, golden, trace or cycle band was changed.

Native guest exit is zero, actual delivered faults zero, V retirements **66**,
and the real AXI backend runs at read/write latency seven. The diagnostic
correctly exits 1 for the reproduced differences; systemd records failed exit,
MainPID zero and no remaining cgroup. This is a closed bug witness, not a pass.
Root: `external/tmp/ventium-fst-memory.dPaxs129/observation-r1/`, invocation
`4b6a4b91105243b0b9fae281c67eb12f`.

## Compact implementation and closed directed verification

`prepare_fst_memory_c1.py` changes only:

- `fpu_x87_pkg.sv`: expose the **existing** rounding-increment decision from
  f32/f64 conversion. Overflow selects the same infinity/finite-saturation
  branch already used for the value. Compatibility wrappers preserve every
  old value/exception bit and width.
- `ven_fp_misc.sv`: register that one-bit sideband beside the existing result,
  resetting/defaulting it to zero; m80 requires no numerical conversion.
- `ven_fp_top.sv`: the completing memory-FST owner writes C1, including exact
  operations with no sticky exception to merge. Other miscellaneous operations
  retain their existing handling and require separate correctness work.

There is no additional converter, adder, pipeline stage, queue or occupancy
change. Those are source-level properties, **not an area/timing measurement**.
This does not repair legacy memory-store C1, FIST/FRNDINT/FSCALE semantics or
unmasked-result suppression; none is silently included in the claim.

Eleven host matrix/recipe tests pass. The exact private derivative is
`external/tmp/ventium-fst-memory-core.KeXO3LAk/`; all 651 inherited source pins
were checked before preparing it. It preserves the parent's shared arithmetic,
forwarding and register-FST repair and changes exactly the three files above.
The build keeps the same defines, its own uniquely named C++ harness/header,
strict structural errors and the normal shared build lock.

Service `ventium-fst-memory-core-oct10.service`, invocation
`d483d1d93def42c6b316d8d80eebd82d`, has closed. Model **12086691** builds native
0 with stable pins and its own generated-header dependency. All **2,352**
directed cases then pass: **zero repaired-RTL or native discrepancies**, all
memory values/flags/stack/width checks intact, real V retirements 66. The
pinned QEMU still has the same 1,176 C1-only differences; the mathematical
oracle and native execution agree. Directed native exit is 0.

The unchanged canonical `make verify`, explicit UV-fast/AXI latency-seven
in both functional/cycle jobs, closes **native 2 / FAIL**. It reports seven
functional passes and 101 failures: 91 terminal-length differences and ten
earlier x87 C1 differences, plus the existing hard cycle-band failures.
No masks, goldens, terminal records or bands were changed. The controller
therefore honestly closes failed exit 1; its closure is archived by the
metadata keeper. Full standard-suite, gameplay and hardware acceptance
remain open. The frozen FPGA sources do **not** contain this repair.
