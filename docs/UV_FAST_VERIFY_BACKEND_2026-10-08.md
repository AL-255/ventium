# UV-fast verification backend audit — Oct 8, 2026

**Verification configuration repair, not a processor or Quake repair.** The
current FPGA image `1c8f20ac` and the payload candidate have no qualified gameplay
IPC. Historical `53f129e9`: **0.1659957781052303 primary/U-counter IPC**, not total
U+V, over 127 qualified intervals with gaps within cycles
8,721,490,845–19,169,282,165. It predates these candidates.

## Finding and change

`+define+VEN_L1_AXI` compiles the backend but does not select it. In `tb_main.cpp`,
`Args.l1_axi` defaults false; only `--l1-axi` drives `l1axi_en=1`. The previous
generic UV-fast `make verify` runs used direct memory. In addition, the unified
worker applied `TB_EXTRA_FLAGS` **only to functional jobs**; its cycle jobs had
no equivalent option passthrough. Their 4,154-clock `mb_dmiss` result was not an
actual L1/AXI miss measurement. This does not invalidate separately recorded
directed runs whose commands explicitly selected `--l1-axi`.

The worker now accepts a separate, whitespace-delimited `TB_CYCLE_EXTRA_FLAGS`
and saves the exact cycle invocation as NUL-separated `*_rtl.argv`. It rejects
functional trace format, trace discard, STEP and breakpoint flags for these
cycle jobs. Existing default behavior and all comparators/goldens/bands remain
unchanged. To exercise AXI in both halves of the gate with a suitable prebuilt
UV-fast model:

```bash
export TMPDIR=/home/yukidama/external/tmp
export TB_BIN=/absolute/path/to/private/obj_user/tb_ventium
export TB_EXTRA_FLAGS="--cycle-func --l1-axi --quiesce 200000"
export TB_CYCLE_EXTRA_FLAGS="--l1-axi --quiesce 200000"
export AXI_RLAT=0 AXI_WLAT=0
# Set VERIFY_WORKDIR to a new private directory on the external filesystem.
make verify
```

Do not infer UV-fast or AXI acceptance from this command alone: pin the model's
complete defines/source closure, verify actual V retirements, check backend
activity, and grade the native results. Zero added AXI slave latency still
includes the RTL bridge/cache protocol latency.

## Native regression, no simulator rebuild

[`test_verify_worker_backend.py`](../verif/lib/test_verify_worker_backend.py)
invokes the real worker, pinned Pentium QEMU/plugin and prebuilt model. It checks
required fast-path defines, identical instruction sequences, same-clock U/V
pairs, actual L1 backing ACKs, and exact argv. Four negative controls reject
`--cycle-func`, `--no-trace`, `--dbg-step`, and `--dbg-bp`. Functional flags are
deliberately present in its environment to verify that they do not leak into
cycle jobs. Every input is hashed before/after; each native case is capped at
60 seconds and runs in parallel. Output stays in external scratch.

```bash
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 verif/lib/test_verify_worker_backend.py --tb /absolute/path/to/tb_ventium
```

Closed result: **7/7 option/backend checks pass**,
`/home/yukidama/external/tmp/ventium-worker-backend.9dvutm42/result.json`.
Payload user model SHA-256:
`b24fb45044ff1547db50174125861d680632e9ab6eb0fa50880a6ea053684e6a`.

| `mb_dmiss`, unchanged 8,204 instructions | Direct control | AXI, latency 0 | AXI, latency 7 |
|---|---:|---:|---:|
| Final clock | 4,154 | 41,037 | 270,619 |
| Paired V retirements | 4,101 | 4,101 | 4,101 |
| L1 backing ACKs | 0 | 16,400 | 16,400 |

These are directed measurements, **not gameplay IPC or cycle-band passes**.
All three retain the native cycle comparator's failed 20,524-clock reference
band. The older `backends/result.json` diagnostic in `ventium-uv-gate-boundary.l5N3vx`
is red because its first grader incorrectly expected `dbg_rd_valid`-based
`rd_beats` to be nonzero in this non-KV model. The actual cache counters above
are the relevant witness. The original red result is retained, not overwritten.

## Full AXI corpus: still failed

`ventium-uv-gate-boundary.l5N3vx/axi-verify` runs all **108 functional + 20 cycle**
jobs with AXI explicitly selected in both modes. Native `make` exit **2**,
136.7-second parallel phase, source/binary pins unchanged. All functional jobs
execute with `cycle_mode=1` via `--cycle-func`; no slow-mode substitute.

- Seven functional comparisons pass.
- All other **101** report **length mismatch only**; no earlier architectural
  field divergence is reported. One is the paired max-instruction boundary
  (`mb_jmppair`, 5,000 versus 5,001 records). The other 100 have the user-mode
  terminal record included by cycle-mode RTL but absent from the GDB functional
  oracle, which cannot read post-state after process exit.
- Hardware-backend cycle counts differ from legacy direct-model bands. For
  example `mb_dmiss` is 41,037 versus 20,524 and `mb_imiss` is 66,330 versus
  24,115. These are visible failures, not a reason to loosen the bands silently.

No records were dropped, oracle post-state fabricated, comparator weakened,
or core issue mode changed. The generic gate remains **FAIL**. A well-defined
terminal/bounded-observation contract is still needed before it can serve as a
green generic UV-fast gate. Both CoreMark seeds, Win95 desktop and original
40 MHz FPGA Quake timedemo/movie remain unqualified for this candidate.
