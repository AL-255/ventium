# SRT exponent ownership and C1 matrix — October 9

**Private numeric backport; not promoted.** The original leaf now passes all
912 value/exception/latency cases and reset cancellation. The historical
pre-build investigation below is retained with its original scope.

At **15:49 UTC October 10**, the newest directed UV-fast core `db83a397`
reproduces the same four wrong values and 456 C1 failures with the actual
L1/AXI backend at read/write latency seven. All 912 native-x87/QEMU values
agree; native x87 C1 agrees with independent exact arithmetic. Real V
retirement and normal guest exits are observed. The original diagnostic exits
**1**, as it must; it is not a correctness pass. Evidence:
`ventium-srt-floor-current.XYzJp8Rj/parent-observation/result.json`, supervisor
`ea8606c232cf48f7a68380879f70e7a1`.

[`prepare_srt_round_floor.py`](prepare_srt_round_floor.py) mechanically applies
only the three numeric hunks to this latest candidate. Five host guard tests
pass; the resulting engine is byte-identical (apart from its test module name)
to the independently closed 912-case leaf. Both sequential blocks, all ports,
recurrence, completion timing and the existing C1 behavior are unchanged. The
new full-core build retains every performance/payload define and changes only
`rtl/fpu/fpu_srt_div.sv`; it does not replace the shared/forwarded FPU wholesale.
The numeric patch **does not fix C1** or waive the red canonical gate.

The bounded worker `ventium-srt-floor-current-queued-oct10.service`, invocation
`611fec2d6cd146389c1ea67e9ec196ab`, waits for the already-running native FPGA
timing inspection. It then owns the independent clock auditor and requests
the private full-core build, original 912-case observation and unchanged
`make verify` with AXI7/UV-fast. Native build/gate caps remain 600 seconds;
queue waiting is separate. Neither production RTL nor the frozen FPGA input
is changed.

At **16:00 UTC**, the strict full-core build closes native 0 in **17.50 seconds**:
model `b1cb5dc8b58c4f671871455952d25c1827a41c856b692b81281b42a8f7d5232f`.
Its independent `numeric-audit.json` verifies **4,331 stable build pins**, the
one-file source delta and exactly unchanged defines. The unchanged ordinary-entry
fixture now has **zero numeric mismatches in 912 cases**, fixing exactly cases
160/198/464/502. Native/QEMU authorities, input ELF and every pre/post status
word remain identical. Parent and candidate each take **532,305 clocks for
10,062 retired instructions**, and all printed profile counters are byte-for-byte
identical, including 21,008 backing ACKs and actual V retirement. This is a
directed zero-cycle-cost result, not a gameplay speed measurement.

The original observer still correctly exits **1** for the **456 unchanged C1
failures**. Numeric success is not whole-observer acceptance. The actual
unmodified AXI7/UV-fast `make verify` has closed **native exit 2 / FAIL**:
7/108 functional passes, 101 failures, and 12/19 scored cycle-band failures.
The independent `generic-audit.json` confirms all **20 complete cycle-record
lists are identical to the parent**, with all 4,331 build pins stable. No
mask, golden or band changed. The supervisor's exit 0 records successful
orchestration only; its retained native gate receipt remains exit 2. No own
full-PC/standard-suite qualification is granted.

Current verified gameplay baseline is **0.49940993 U+V retirement-event IPC**,
`bfb867f7`, clocks 3,200,065,237–3,300,065,237; all 21 windows average
**0.4895819671**, retaining the new 0.45825794 dip. This repair has no gameplay measurement or standard-suite
acceptance. The performance baseline's qualified scores are 2.101890118 /
2.107616105 CM/MHz, not scores measured on this new derivative.

## Historical initial observation

`run_srt_c1_observe.py` executes 912 finite FSQRT/FDIV cases on native host x87,
pinned `qemu-i386 -cpu pentium`, and the actual current CoreMark model
`b5453f16119f8b59d744cd2bb26eef38b683cbddf20bf3f215d259d5baa577f9`.
It covers PC24/53/64, all four rounding modes, both initial C1 values, exact
results, nearest-even ties, signed division, subnormal and exponent-boundary
inputs. `FNSTENV`/`FLDENV` seed C1 architecturally in this directed fixture;
there are no debugger state writes or post-init snapshots. The ordinary
ELF-entry loader runs zero guest instructions before capture. This is not a
performance workload or a whole-instruction differential gate.

The fixture writes every actual pre/post status word and 80-bit result before
normal guest/native exit0. Actual fault deliveries are zero, real V retirement
is nonzero, and UV-fast `--cycle-func` is retained. Exact integer/rational
comparisons independently confirm native C1 for all912 cases: square the
observed root or multiply the observed quotient by its divisor, then compare
magnitudes with the exact input. This uses no host floating-point approximation.
Native host x87 is not claimed to be physical P54C.

Evidence: `external/tmp/ventium-fp-c1-observation.lWKLSGKN/matrix-r1/result.json`,
SHA256`082613e032ab1f0ac4f42d4af91ab935b15cdf0eda786191709d9f87c75b5e46`.
ELF SHA256`867acbe7ac5dd58d8e156660c9ba3c47e37d005af0de0779b60908c004404cec`.
Bounded supervisor invocation`be096af835e14e54b1a2d743d3b9d8f3` closed with
the diagnostic's intentional **FAIL exit1** (not a correctness pass), using
about51 MiB and less than one second. All subprocesses exited normally.

## Results

- **456 C1 mismatches:**216 FSQRT and240 FDIV. RTL retains the seeded C1 instead
  of committing the owning arithmetic operation's final rounding direction.
  QEMU also does not supply the required C1 oracle; its C1 is not treated as
  ground truth. See [the exact-FSQRT witness](FSQRT_C1_PERSISTENCE.md).
- **Four numeric mismatches**, all in RTL; native x87 and QEMU agree. Input
  `7ffeffffffffffffffff`, FSQRT, RC=+infinity, PC24 or PC53, either C1 seed:
  expected`5fff8000000000000000`, RTL`60008000000000000000`—twice the value.
- The remaining908 values agree across all three observers. This is not broad
  arithmetic or standard-suite acceptance. Overflow, invalid operands,
  unmasked faults, owner overlap and complete random coverage remain outside
  this fixture.

## Root cause and proposed compact repair

In `rtl/fpu/fpu_srt_div.sv`, the inline PC64 path increments `msb` when its
rounding carries. The independently rounding reduced-precision packer then
receives that **already-rounded exponent**, but the **unrounded significand**.
Its own carry increments the exponent again. A nearby floor-borrow adjustment
is also tested after its MSB has already been replaced with1, making that test
ineffective.

[`srt_round_floor.patch`](srt_round_floor.patch) keeps the unrounded exponent
owner separate and applies the floor-borrow exponent change before replacing
the significand. No new recurrence, register stage, duplicated divider or
serialization is proposed. `git apply --check` passes against original SRT
SHA256`62c662f7e1608c100e4853a12b3282aefa729bb49b6dd519cdb9404a94f87b52`.
The patch is deliberately **not applied to production or the frozen FPGA input**
while its native build is in flight.

[`tb_srt_round_floor.sv`](tb_srt_round_floor.sv) is the prepared old/new leaf
gate. Build the original engine beside a private patched copy renamed only to
`fpu_srt_div_floor_candidate`, plus `rtl/fpu/fpu_x87_pkg.sv`. Its `+vectors=...`
file consists of912 whitespace-separated hex rows:
`mode pc rc input_a input_b expected_native_value` (`mode`0=FDIV,1=FSQRT).
Require each stored native value to equal QEMU before exporting that row.
The gate requires all912 candidate values, exactly four original failures,
unchanged completion clocks and OE/UE/PE, and reset cancellation. It is **not
yet successfully compiled/run**. Private sources/vectors and `run_leaf.py` are
prepared in `external/tmp/ventium-srt-floor-leaf.vNu0mw59`; source and vector
hashes are checked before/after. A lightweight Icarus attempt closed with
native exit50 because that compiler lacks the actual source's SystemVerilog
`break`/automatic-lifetime support (log retained); no RTL was rewritten to
work around its compiler limitations.

The real Verilator leaf is queued as `ventium-srt-floor-queued-oct09-r2.service`,
invocation`385729e9fbc9492c89890f4db1d7cc8d`. It waits for Vivado to release
the shared build lock, then gets the normal4GiB/one-job scope and a600-second
build/run bound. It cannot start a concurrent hardware build or change frozen
FPGA inputs. `closed.json` must actually pass; queue admission is not evidence
of a repair. Broaden power-of-two neighborhoods and underflow/overflow
before promotion, then rerun full-core differential and standard suites.

The numeric patch does **not** fix C1. C1 must travel with the real final rounding
decision (including ties and SRT over-estimate correction) and commit with its
owner; simply copying PE, always clearing C1, or loosening masks is not a repair.

Host fixture checks: `python3 -B fp_shared/tb/test_srt_c1_observe.py`—five PASS.
