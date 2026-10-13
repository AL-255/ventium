# Private QEMU remainder-quotient qualification

October 13, 2026. This repairs a diagnosed **reference implementation** gap;
it is not an RTL performance fix, canonical-oracle promotion or FPGA acceptance.
The installed FPGA Doom image still fails on memory SMSW. No guest code changed.

## Defects and repair

QEMU 8.2.2's `floatx80_modrem` passes a null quotient pointer for nearest-even
remainder. Its internal helpers overload that pointer to select remainder
versus truncating modulus. Consequently FPREM1's architectural helper receives
zero quotient bits even when the numeric remainder is correct.

`prepare_remainder_quotient.py` derives two exact-hash-checked private sources:

- Carry an explicit `mod` Boolean through the parts/fraction helpers, separate
  from the optional quotient output. Existing binary32/64/128 remainder callers
  explicitly retain nearest-even mode.
- When nearest-even selects the complementary remainder, increment the quotient
  magnitude, including odd/even ties. Return its low 64 bits in both x80 modes.
- Correct an additional quotient-accumulation defect exposed by the new tests:
  above the first 64-bit division step, the estimated quotient digit belongs at
  the current exponent-difference bit position, not at the low end of a radix
  2^61/2^62 digit stream. Accumulate `q << exp_diff` when that contribution fits
  the requested low 64 bits, then add the final digit. Remainder subtraction,
  normalization, rounding and exception calculations remain unchanged.

For example, `(1.25 * 2^65) / 1` is exact. Its quotient's low 64 bits should be
`0x8000000000000000`; the original truncating helper returns
`0xffffffffffffffc8`. The first private attempt only separated the mode/output
and failed **3,456** exact quotient checks (1,728 in each x80 mode). That failed
run and its original source/driver copies remain as `remainder-quotient-r1`.
No tests were removed to conceal this defect.

The x86 helper's partial-remainder path itself reduces the exponent gap before
calling SoftFloat. This qualification does **not** establish instruction-level
partial-reduction sequencing, C2 behavior, exception delivery or all x87 flags.
Those require a separately built and tested private QEMU. Canonical QEMU,
goldens, masks, comparators and cycle bands remain unchanged.

## Native tests

Evidence root:
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI/remainder-quotient-r2`.
Four private native probes compile the actual pinned QEMU SoftFloat sources:
original control, proposal, missing-nearest-increment mutant and wrong-mode
mutant. Every build uses the original target configuration/includes and checks
the complete compiler dependency closure before and after compilation.

All four execute the same **19,008** records:

| Operation | Cases |
| --- | ---: |
| x80 nearest-even remainder | 7,584 |
| x80 truncating modulus | 7,584 |
| binary32 / binary64 / binary128 remainder | 1,280 each |

Exact rational/integer quotient expectations are independent of SoftFloat and
RTL outputs. Inputs cover both signs, all four rounding controls, all three
x80 precision controls, half-way ties and neighbours, zero/NaN/infinity/invalid
x80 encodings, subnormal boundaries, 63/64/65 and 125/126/127/128 exponent gaps,
large gaps, low-bit wraparound and deterministic randomized significands.
The output pointer is poisoned before each call to expose missing resets.

- Proposal: **zero quotient mismatches**. Every remainder value and exception
  word equals the unchanged original control on all 19,008 cases.
- Original control: **6,864 quotient mismatches**. Of these, 1,728 truncating
  outputs change in the proposal; each changed output matches the exact oracle.
- Missing-increment mutant: **1,824 quotient mismatches**, with numeric values
  and exceptions still identical to control.
- Wrong-mode mutant: **1,824 quotient and numeric/exception-record mismatches**.

Unit `ventium-remainder-quotient-oct13-r2.service`, invocation
`caf24d5e6ce046afb329c03adc32df6c`, is terminal with MainPID 0 / exit 0.
Native work took **11.91 seconds**, peak **163,004,416 bytes**, on CPU13, under a
1 GiB RAM / no-swap / 600-second cap. The independent closed-run audit rechecks
all raw records, binaries, cases, negative controls and **371 input pins**.
Closure SHA-256:
`3034755e0a986722ab8d73332223ab85c3462d6eff2b033e1236f4bc446ac3a7`.
Proposal probe SHA-256:
`8f8dc71552f40c47bc5f313a9d8cccdfb85dd0ebe439c31373442c9fecdd8f48`.

Seven source/oracle host tests pass. An initial source-only preparation refused
an ambiguous indentation anchor; newline-anchored replacements fixed it without
weakening source hashes. No full QEMU or FPGA rebuild was required for these
standalone tests.

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  taskset -c 13 python3 -B verif/qemu-trace/test_remainder_quotient.py

TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  taskset -c 13 python3 -B verif/qemu-trace/audit_remainder_quotient.py \
  --run /home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI/remainder-quotient-r2 \
  --unit ventium-remainder-quotient-oct13-r2.service
```

The runner requires a fresh external output, matching pinned QEMU source/build
compile database, a bounded systemd invocation, CPU13 affinity and at least
4 GiB free. It writes only private source/probe/output copies, not `--build`.

## Remaining acceptance

Compose and qualify this with the separate [round-increment event](ROUND_INCREMENT.md),
instruction-specific C1 helpers and terminal-observer/cache-key corrections.
The canonical gate remains **7 PASS / 101 FAIL**, unwaived. This local reference
repair does not resolve processor cycle-band failures or qualify any guest.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates the candidate and is not FPGA/Doom
IPC. No performance gain is claimed for reference qualification.
