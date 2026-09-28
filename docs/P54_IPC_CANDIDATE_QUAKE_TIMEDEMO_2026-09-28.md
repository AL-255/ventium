# P54 IPC candidate: Quake timedemo cold run (2026-09-28)

## Scope and provenance

This is a cold-reset, full-PC run of the current `ven-ipc` candidate. It uses a
private writable copy of the unmodified FreeDOS/Quake disk; AUTOEXEC launches
`quake -nosound -nocdaudio -condebug +timedemo demo1`. No native snapshot from a
different RTL build is restored. This run is a performance and workload check,
not a claim of FPGA timing closure or completion of the differential gate.

| Input | Identity |
| --- | --- |
| Git commit | `ff0a80397798672f27632ad7af8f51d16277a342` |
| Build target | `make -C ao486-sim ven-ipc` (`VEN_IPC_P54_TLB_DEFS`) |
| Frozen simulator SHA-256 | `97baa1f4cc9b78cdbc2c8629fda6610d123d8b1d0f6ef5e507927f989aed1a3f` |
| Cold disk (`tmp/qk_td.vhd`) SHA-256 | `2df14ac9ae5f927cab2410e784d14c655f0e96644ca80ced3c0b012df7a36e4c` |
| BIOS `boot0.rom` SHA-256 | `dca915c5483793a710ee118c5232aad01ef3191bea7d50c2befb1a47d2dd26a3` |
| BIOS `boot1.rom` SHA-256 | `fb0d673a4cc3a96c388b4404db262db70bdde0746ee1ef9284923a5661e08296` |
| Full run directory | `/home/yukidama/ventium-bg-sep28/quake_candidate_ff0a803/` |

The run uses the repository's `ao486-sim/ven/run-gameplay-capture.sh` with
`SAVE_CYCLE=1400000000`, `RUN_TIMEOUT=21600`, 45 MHz core/RTC, 90 MHz VGA,
32 MiB RAM, `FPGA_DDR=2`, fixed `AO486_RTC_EPOCH=1789257600`, v3 snapshot,
50M-cycle performance/text/frame sampling, and CPU affinity 29. The wrapper
records `inputs.sha256`, `settings.txt`, `capture.log`, and a snapshot/disk
receipt in this directory. The bundle at 1.4B cycles passes
`python3 tools/checkpoint_bundle.py` (`CHECKPOINT-BUNDLE-OK`). The two prior long Quake
and Win95 jobs use different disk copies and CPUs 30 and 31.

## Gameplay measurement

The first two visually confirmed candidate gameplay frames are at approximately
950M and 1,000M cycles. Their profiler samples bound an **early, 50M-cycle
gameplay window**, 950,000,531–1,000,000,531: 24,895,167 legacy retirements /
50,000,000 clocks = **0.49790334 IPC** (2.008422 CPI). The scene also advances
at 1.05B and 1.10B. The measured **150M-cycle gameplay interval**
950,000,531–1,100,000,531 has 73,452,062 retirements: **0.48968041 IPC**
(2.042148 CPI). A longer confirmed gameplay span, 950,000,531–1,250,000,531,
has 141,756,328 retirements in 300M clocks: **0.47252109 IPC**.

The primary matched-cycle comparison uses active-gameplay frames at both ends:

| Build | Actual 200M-cycle window | Retirements | IPC | CPI |
| --- | --- | ---: | ---: | ---: |
| Current `ff0a803` | 1,150,000,531–1,350,000,531 | 90,900,693 | **0.454503465** | 2.200203 |
| Frozen pre-candidate | 1,150,000,165–1,350,000,165 | 87,888,831 | 0.439444155 | 2.275602 |

The candidate's equal-cycle IPC is **3.43% higher**. This is not a fixed-work
speedup: the two builds can be at different points in the demo at equal cycle
counts. The candidate adds 3,011,862 retirements in this window, of which
2,783,347 are V-slot events; that observation is consistent with more pairing
but does not by itself prove pairing caused the entire difference. The run
still falls far short of the CPI < 1 objective. Timedemo completion remains
pending. Do not substitute boot or Quake
initialization IPC. The frozen **pre-candidate** binary
`c06a2d00ddb7b308e60c598f6a2497ec52c9f8bc7f93c430c02f605814398631`
measured 109,055,232 legacy retirements over 249,999,835 clocks, cycles
1,150,000,165–1,400,000,000: **0.436221216 IPC** (2.292415 CPI).
This is a baseline, not the current candidate's result.

The final longer candidate measurement, computed by differencing cumulative
`[VEN-PERF]` samples with `tools/cpi_interval.py`, is **114,304,432
retirements / 249,999,469 clocks = 0.457219 IPC** (2.187137 CPI), cycles
1,150,000,531–1,400,000,000. The 1.4B-cycle endpoint is the planned
save-stop checkpoint; the latest frame before it still shows gameplay. These
are legacy retirement events, not a fixed-work speedup or FPS measure. A
same-cycle window may cover different guest work on the candidate and baseline.

The 150M-cycle profiler window recorded 16,103,261 secondary (V-slot)
retirements, 21.9% of all retirements, and 12,411,342 explicitly paired U/V
issue clocks. Multi-issue is active, though this does not prove every P5 pairing
or precise-event corner. An unresolved memory request occupied 39,436,640
clocks (26.3%); memory was the first `S_PIPE` block on 21,181,390 (14.1%).
FP issue/occupancy was the first block on 13,792,911 (9.2%) and uop-cache
unavailability on 12,773,370 (8.5%). These counter families overlap and do
not separate L1 misses from hit latency or AXI service. The existing bounded
FP/integer overlap and FP/stack microbenchmarks passed architectural QEMU
comparisons and observed integer progress during outstanding FP work; this
gameplay profile is not by itself an exhaustive FP-overlap correctness gate.

## Outcome

Quake timedemo has reached active gameplay on the current candidate. The
matched 200M-cycle and final 250M-cycle gameplay IPCs above are measured. The
run stopped intentionally at the 1.4B-cycle checkpoint, so the timedemo's
completion/FPS were not measured. No RTL changes were made during this run.
