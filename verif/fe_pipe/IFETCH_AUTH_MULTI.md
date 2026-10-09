# Multi-page instruction permission shadow — October 9

Private performance candidate; **not selected for FPGA or standard-suite
acceptance**. Current verified Quake gameplay is **0.39555990 total U+V IPC**,
model `05611d6c`, cycles **1.2–1.3B**, predating this change. The candidate has
no gameplay measurement. The ≥0.48 target remains open. The combined parent's
full direct-memory CoreMark scores are **2.107363183 / 2.110412882 CM/MHz**;
these are not this candidate's scores or FPGA/cache-backed measurements.

## Cause and change

`if_auth_ok` remembers only one instruction page independently of the shared
translation address. A data access names DS/SS:EA, so that shared address
cannot serve as the frontend's permission proof. But the one-page shadow
also makes ordinary inter-page CALL/RET loops repeatedly enter checked
`S_FETCH`, even with warm I-cache and parent I-TLB entries.

`VEN_IFETCH_AUTH_MULTI` replaces only that permission lookup with a 16-entry,
direct-mapped shadow: full 20-bit linear-page tag, raw U/S bit and validity.
The query remains `flin`; capture remains the original successful checked
instruction translation at `cur_lin`. There are no cached CPL0 allow bits:
every lookup rechecks the live CPL. Paging-disabled behavior is unchanged.

Every context flush and **every I-parent TLB fill/replacement** clears all
valid bits, with invalidation beating capture. D-parent fills do not evict
I-parent state. Invalid tag/user payload needs no reset. Byte residency,
returned BRAM identity, snoops, CS extent, demanded boundary fetch, faults,
interrupts, debugger, decode, execution and retirement are unchanged.
This is a permission-only shadow, not another data/instruction cache, new
speculative bus request, guest-specific path or saved-state workaround.
Full-chip area/timing remains unmeasured.

The recipe changes one existing assignment in a private frozen source tree
and adds `core_ifetch_auth_multi.svh`. The default-off branch is byte-identical
to the original assignment. Production RTL/filelists are not changed.

## Closed evidence

Root: `/home/yukidama/external/tmp/ventium-ifetch-auth.r6vwoS44`.
Board-profile model:
`2a14f6e45caf6753440674c39500504870319a2ed2eb4cb2400bac6370ad500c`.
Full-address generic-test model:
`148ee90d466d4aac4c965296f1bc3bccae0fd8e5bc3023b27fe6a6da8f6b7947`.
Both preserve U/V, relocated system fast path, fast loads/stores and AXI.
Private harness objects use their own generated headers; input pins are stable.

- `leaf-r1`: **8,535** actual-include checks: sixteen pages, all four CPLs,
  offsets, colliding full tags, permission refresh, individual capture guards,
  reset/flush/I-parent-fill dominance and independent D traffic.
- `matrix-r1`: **288 full QEMU architectural comparisons**, plus corresponding
  complete cycle traces and real V-retirement witnesses. Nine ordinary control
  kernels × two segment bases × four line offsets × two models × AXI0/7.
  No measured warm-loop regression in the 144 matched comparisons.
- `fault-r1`: **16 full QEMU comparisons** plus cycle-mode counterparts. Warm
  supervisor code is entered at CPL3 and must PF5 before its first effect;
  handler checks the entire error frame, CR2 and untouched counter, permits
  the page, invalidates with INVLPG or CR3, and retries without editing the
  saved frame. Another case revokes a warmed user page before entry. Physical
  remapping requires execution of the new code signature, not stale bytes.
- `system-matrix`: **76** existing complete system QEMU cases pass with
  architectural parent parity. These are not OS acceptance.
- `boundary-l0` / `boundary-l7`: **44** complete fetch-boundary checks pass,
  including missing essential bytes, unused lookahead, exact restart PC,
  maximum instruction length and privilege/x87 exception precedence.

Representative relocated offset17, AXI0 warm loops:

| Kernel | Parent clocks | Candidate clocks | Clock reduction |
| --- | ---: | ---: | ---: |
| Near direct CALL/RET | 47 | 31 | 34.04% |
| Register CALL/RET | 47 | 32 | 31.91% |
| Memory CALL/RET | 50 | 34 | 32.00% |
| RET immediate | 48 | 34 | 29.17% |
| CPU-store-modified target | 89 | 60 | 32.58% |
| Same-set code conflict | 146 | 121 | 17.12% |
| Cross-line callee | 49 | 31 | 36.73% |

These are local kernel clocks, **not gameplay percentage gains**.
The mandatory unmodified generic gate still fails exactly as its parent:
101 terminal-record mismatches and four hard cycle bands. No comparison masks,
record trimming, widened bands or substituted U-only passes were introduced.
This is not a completed modification while that gate and full suite remain open.

## Separate no-gain experiment

`prepare-system-target-read.py` backports the existing two-port resolved-target
address selector to checked system clients. A passive host observer linked
against the unchanged archive proves 32 real selector activations and exactly
identical complete traces, but **72 smoke comparisons save zero clocks**.
Root: `ventium-system-target-read.94xJtPa9`, model `ede8f00f`;
`matrix-smoke-r1` remains FAIL for its required gain. Its original runner is
archived as `runner-smoke-r1.py`, SHA256 `c8422d7b4f62a2524a5e2bd2692a45d2f9cf87f34a43c1472f0e06f2f74db6bc`.
`probe-r2` is read-only and byte-identical to both original trace modes;
`probe-r1` failed compilation on optimized-away diagnostic aliases.
The permission-shadow candidate is derived from the REP parent **without**
this no-gain selector change. Do not silently combine or promote it.

A subsequent, separately identified [combined selector experiment](SYSTEM_TARGET_READ.md)
does save one warm CALL/RET clock after the permission shadow removes the
masking stalls. Its 288 control comparisons, 76 system cases, sixteen fault
cases and 44 boundary cases pass. It is not in this document's full-PC model.

Run the repository microtests using a fresh output on `external/tmp`:

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B verif/fe_pipe/test_ifetch_auth_multi.py
TMPDIR=/home/yukidama/external/tmp python3 -B verif/fe_pipe/run-ifetch-auth-leaf.py --out /absolute/new-leaf
```

`run-system-target-read.py --feature VEN_IFETCH_AUTH_MULTI` accepts explicit
matched `--control`, `--candidate`, `--out` paths. `run-ifetch-auth-fault.py`
uses the same paths and requires precisely this define delta. Both use original
pinned QEMU and complete traces. Run fan-out under the bounded build scope;
full CoreMark, cold Win95/Quake and FPGA qualification are separate next gates.

The matching full-PC model `1f2583cb1e74a7ca59b07d99db8fd4aefb7b322957d6f6411a36b8898d3a6876`
is in `external/tmp/ventium-ifetch-auth-soc.2NYSnknF`. All synthesizable core/FP
files match the qualified microcandidate; registered/read-first XPM state,
P5 L1s, platform L2, posted16 and 40/40/80MHz clocks are unchanged. The existing
98 structural-warning debt items are identical, not newly waived or called
lint-clean. Cold Quake launched on CPU31 with invocation
`56a6b51ae71e4621a589215c80dc3de2`, 2GiB/no-swap/32-task/one-CPU limits.
Native admission is recorded; no gameplay result or timedemo completion yet.
Cold Win95 also runs on CPU27, invocation
`a01ee6b1971f4f129b5abfad87f5fa19`, with the same limits and verified native
admission. Neither guest is accepted yet. Matching direct-memory CoreMark
model `53a2b7d80b7bb50044967bd2acf9b522656e60916276bb8b76aa6943f13c4b7d`
is built under `external/tmp/ventium-ifetch-auth-coremark.Wk20fhLO`; both short
seeds pass full host-equivalence, CRC and negative controls. The measured
host rate has insufficient margin under the unchanged full-seed runtime cap,
so full seeds are not launched. The REP parent's newly closed 2.107861982 /
2.110913372 scores do not transfer to this candidate.
