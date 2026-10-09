# Host-only inactive-L1 evaluation optimization

`tools/prepare_inactive_l1_settle.py` derives the already guarded direct-user
harness for a full-address `VEN_L1_AXI` + `VEN_DBG_CORE` model **without** KV260
address remapping. It does not select the AXI backend, skip guest clocks or
change RTL. Both edge evaluations remain mandatory; only redundant same-clock
settles with every generated input unchanged may be omitted. System/device,
active AXI, debugger, trace and save/restore use remain rejected. Models exposing
SoC interrupt ports are compile-time errors, not assumed inactive.

## Qualification (October 9)

Evidence: `external/tmp/ventium-current-coremark-host-r2.3ixLJTn1/qualify-r1`.
Model SHA-256:
`b5453f16119f8b59d744cd2bb26eef38b683cbddf20bf3f215d259d5baa577f9`.
This is the current WBUF admission-handoff RTL with an optimized private host,
not a new hardware implementation.

- Both ordinary ten-iteration CoreMark seed runs compare **all serialized model
  bytes and all mapped RAM bytes exactly**, optimization off/on within this same
  compiled model. Clocks remain 4,821,818 / 4,815,105, retirements remain
  3,661,024 / 3,656,168, and all five CRCs match each reference.
- 15 native option/environment rejection cases pass; the C++ guard rejects
  22 active-control mutations. An exposed-SoC-port build fails its static assert.
  Two source-recipe unit tests preserve all inherited runtime restrictions.
- Measured host speedups are 1.24378 / 1.24879, with **zero guest clocks saved**.
  This cannot be credited as a processor IPC or CM/MHz gain.
- The first host build (`ventium-current-coremark-host.AjCfYRGX`) failed because
  it tried the board-only guard on absent top-level ports. Its native failure
  is retained. This narrower guard requires the non-KV top's actual RTL ties;
  no missing inputs were fabricated.

Full 1,400-iteration seeds are running separately, with a 3,600-second native
cap each. `verif/bench/prepare_coremark_seed_images.py` obtains entry images
from the unchanged pinned ELF/QEMU, checks the four standard data CRCs, and
records actual reference final CRCs **5275 / f9c3**. Images are not benchmark
save states or edited RAM. Reference fixture generation is not scoring:
duration and `Correct operation validated.` remain mandatory on the RTL run.
Its three unit tests reject wrong data CRCs, iteration counts, sizes, missing
or duplicate fields and unexpected errors.

The first image-preparation attempt rejected QEMU's duration-only generic
`Errors detected` summary; the corrected reference-only checker accepts exactly
that one duration warning with its matching summary. RTL acceptance was not
relaxed. Two full-run launch attempts failed before starting either simulator
(missing explicit CPU affinity, then a private adapter name error); their
receipts remain. Active run `full1400-r3` binds invocation
`2ea5a68a3a0148d9bb4df1655e85309b` to both native children on CPUs2/3, within
2GiB/no-swap and a two-CPU quota. No full result is claimed yet.

Verified gameplay remains **0.44183623 total U+V IPC**, older `652de481`, clocks
1,200,000,000–1,300,000,000. This host candidate is unmeasured in gameplay.
Neither full standard-suite acceptance nor FPGA/cache-backed performance
qualification follows from the host equivalence tests.
