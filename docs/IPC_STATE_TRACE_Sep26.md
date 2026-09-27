# Gameplay IPC: current-build full-state attribution (2026-09-26)

The measured combined wave9+VGA executable is SHA256
`b278c988be64f7eaae0ab56b21faafd5dfcee250984136c9dd628a332513c247`.
At clocks 1,100,000,000–1,101,000,000 its 1,000,000-cycle native state trace
records **0.564642 gameplay IPC** (564,642 edge retirements). The broader
same-build 1,050–1,100M window records **0.44577548 IPC**; the short trace is
not a substitute for that representative window. No new RTL candidate has a
gameplay measurement yet, and neither figure proves Quake timedemo completion.

Evidence: `tmp/build-tmp/ventium-state-delta.7sh8i_6b/` is a same-model,
cold-boot-derived checkpoint replay. The 1,000-cycle host-only relink pilot
matches the frozen executable's native snapshot and private disk byte-for-byte.
Recorder OFF and ON also finish with byte-identical native snapshots and disks;
the input bundle was hash-checked before and after. The frozen RTL archive
SHA256 is `b543bb6439b50c3061a146f09848daba517b9962f33993c4cf4f83eecd5c178b`
before and after relink. The trace contains every settled retained field on
every cycle (12,978 fields, 681,916 reconstructed state bytes), but not external
DDR, PS/ATA or disk state. The analyzed outputs are under
`tmp/build-tmp/ventium-vga-wave9-analysis-sep26/wave9.*`. The analyzer's phase
test and all 53 current-schema synthetic attribution cases pass. This is an
observer check, not a differential architectural oracle.

The analyzer assigns each of 558,119 edges without retirement to exactly one
priority bucket. They sum to 100%; overlapping raw signal levels do not:

| Bucket | Edges | Share of no-retire edges |
| --- | ---: | ---: |
| Outside the fast pipeline | 176,972 | 31.71% |
| Pending-FP hold | 138,037 | 24.73% |
| Memory wait, including admission | 136,780 | 24.51% |
| Ready but control-limited | 54,343 | 9.74% |
| Frontend unavailable | 51,239 | 9.18% |
| Deferred fault | 748 | 0.13% |

The raw L1 read-wait level is high for 215,107 clocks, of which 118,631 are
busy backing service and 92,349 are idle registered-hit capture. Those levels
overlap useful retirements and other causes; they must **not** be added to the
disjoint table or interpreted as saved cycles. Of the 215,107 clocks, 207,072
name data and 8,035 instruction requests. Current optional L1 flags have only
small exposed bounds in this short window: fill-forward 1,394 eligible clocks,
independent hit-under-fill 5,058, and preserving the read window across stores
7,032. These are eligibility observations, not end-to-end IPC predictions.

The FP hold is entirely concentrated in S_PIPE (138,037 no-retire edges). Raw
descriptor observations while held include 66,608 branch-level observations,
42,532 frontend-unavailable observations and 28,753 register-FP descriptor
observations. They are not a proven branch-overlap savings estimate: after a
branch, another FP dependency or frontend repair may become the next blocker.
The source deliberately blocks branch and slow/dependent issue until the older
shared-FP result is complete; removing that interlock requires fault, event,
debug, SMC and x87 retirement-order proofs, not just a throughput microbench.

The outside-pipeline bucket includes slow decode, load, FP operand, execution
and shared-response states. In the raw state residency, S_FLOAD is 83,498 clocks,
S_FEXEC 32,350, S_FP_SHARED_WAIT 20,807, S_LOAD 24,082 and S_DECODE 33,026.
These are not all stalls: edge retirement can coincide with some of them.
`0x10f4a` (FILD dword memory source in this workload) occupies 20,366 S_FLOAD
clocks across the sampled visits; its latency must be split into cache/translation
and x87 admission before changing the converter. The previous text trace already
showed variable memory-service delays here.

The current million-cycle window has no rows in the joined VGA-service report;
an earlier build/window had a VGA write hotspot, so do not generalize this
absence to the 50M gameplay interval. The next performance candidate should
first prove a specific removable edge class with a current-build A/B replay.
Priorities are (1) eliminate provably redundant slow-path transitions, (2)
extend independent integer/FP overlap with precise event and x87-state gates,
and (3) pipeline registered cache-hit ownership without combinational BRAM
acknowledgements or speculative MMIO. Keep full-system Quake/Win95 and QEMU
differential acceptance separate from any native-checkpoint throughput result.
