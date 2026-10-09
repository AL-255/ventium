# x87 resident-window admission experiment — October 9

**The original priming-only experiment has no steady-state gain.** The later
[forwarding + arithmetic-only priming combination](FP_MEMORY_FORWARD.md#combined-arithmetic-only-priming)
does show a directed gain, but is not promoted either. Neither experiment is
part of any full-PC run or FPGA image. Verified gameplay
baseline is now **0.38065044 total U+V IPC**, dispatch-only `ba2463bf`, cycles
**1.2–1.3B**; neither this experiment nor its raw-prime parent is measured.
The preceding posted16 baseline was 0.37026314 over 1.2–3.0B (different window).

`prepare-fp-resident-prime.py` uses the existing resident-read query port to
capture the current x87 operand's cache window on its checked admission edge.
S_FLOAD retains request, translation, fault and command ownership. It adds no
backing prefetch, third decoder, early retirement or new arithmetic unit.
Operand line/segment extents, TLB permissions, event/debug and cache
invalidation checks remain required.

The first build (`ventium-fp-resident-prime.ktJbvmlt`) failed hard UNOPTFLAT:
ACK-dependent `fp_shared_mem_admit` drove the lookup address. The r2 generator
separates descriptor-only lookup from final checked COMMIT. No warning was
waived. `ventium-fp-resident-prime-r2.0s7m7oPa/build-closed.json` closes native
zero with stable source pins, six hard structural classes, assertions, and a
verified private generated header. Model SHA:
`eb7644eb9d7240bba95286018caf50065356386ed1b06f45aeb0bd34a309e300`.

`fp-resident-prime.S` cold-boots protected paged mode, flat or common 256 MiB
relocation, with aligned or byte-31 code placement. All intermediate QEMU
architectural records, including x87 and CR state, are compared; UV pairing
has an explicit execution witness. No restored state or terminal filtering.

The r2 matrix deliberately **fails its positive-gain requirement**:

| Warm loop | Parent clocks | Primed clocks |
| --- | ---: | ---: |
| Four dependent FADD m32 | 16 | 16 |
| Four dependent FADD m64 | 20 | 20 |
| Four FILD m64 / FADDP pairs | 24 | 24 |
| Split-line m32 negative control | 16 | 16 |
| Split-line m64 negative control | 21 | 21 |

All 16 positive shapes stop at the no-gain assertion after their latency-zero
full QEMU comparisons. The eight split controls finish both AXI latencies
(0/7), giving 16 accepted control measurements. These are **not** 48 passing
performance measurements or a completed correctness suite. Prime witnesses
show real cache capture (56 aligned / 42 alternate-code events in FADD),
not an optimization that never activates.

Diagnostic FADD m32 reruns show S_FLOAD residency dropping 180→124 clocks
while S_FEXEC grows 40→95: almost all removed load waits become arithmetic
admission waits. Whole fixture clocks change only 3298→3297; the steady loop
does not improve. Existing final-result forwarding eligibility explicitly
excludes memory arithmetic, although those forms already share its ST0
operand mux. That eligibility was subsequently extended and tested separately;
the linked forwarding report records both its evidence and remaining gates.

That work was paused when both raw-prime full-PC guests exposed the separate
[primed-U/V ownership regression](PRIME_PAIR_OWNER.md). Do not enable this
flag in production or spend a bitstream build on the original no-gain result.
