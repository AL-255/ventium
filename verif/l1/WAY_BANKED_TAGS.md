# Explicit way-banked tag memories

October 14, 2026 UTC. **Private proposal; not promoted, whole-core qualified,
or installed.** Full-cache equivalence and the synthesis-only cache probe
pass. Way banking restores tag RAM and reduces isolated full-L1 LUTs by
**40.84%**. No whole-chip area or CPU Fmax improvement is claimed yet.

## Measured problem and scoped repair

The [combined next-tag/FP-classifier synthesis](../fp_compare/README.md)
regresses to **32.405457079 MHz unplaced**, with 195,562 LUTs and 60,184 FFs.
Vivado `Synth 8-4767` identifies too many ports on flattened `dc_tag` (16 reads).
Native primitive inventories confirm **5,120 tag FDREs and no tag RAM**;
the preceding current-tag checkpoint has RAM and no tag FDREs. The tag payload
was already excluded from reset. This explains almost all added FFs, but is
not proof that it caused the entire LUT increase or worst timing path.

`prepare_way_banked_tags.py` gives each way an explicit one-dimensional
`L1_SETS × TAGW` distributed array. Each bank has eight asynchronous read
queries in the full profile: paired-store, both paired-load lanes, current,
prime, current+32, prime+32 and snoop. Its write stays inside the identical
fill-completion branch, qualified by `fway`. Valid bits, reset, fill poison,
snoop ordering, LRU, data arrays, response ownership and latency are unchanged.
There is no additional state, feature switch, global stall or guest-specific
behavior. The non-LUTRAM layout remains byte-identical.

The recipe accepts only parent L1 SHA-256
`9b888b991ffc38034899f3c9e98bc1e04f9d37268aaba57cf13e1c0495428311`,
and reverses to it exactly. Candidate SHA-256:
`62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3`.
Four source/fixture tests pass and reject drift/reapplication. Root RTL and
existing frozen sources were not edited.

## Closed full-cache equivalence

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.
`way-banked-tag-cache-r1` reuses the complete prior public-traffic cache
fixture. Its only fixture edit maps the candidate's bank names to the old
flat index: **all tag bits, valid/LRU/data banks, outputs and owner/state
comparisons remain**. No hierarchical writes initialize or force cache state.

- **747,037 both-edge state comparisons**, with byte-identical cycle trace.
- The same 361,977 next-line-hit, 463 next-owner and 6,984 crossing samples;
  these overlap and are not unique requests.
- All prior reset/read/store/coherence and fresh-pair stimuli remain;
  fresh-pair coverage is 51 cases, 41 pairs, 123 held responses.
- Two independently compiled negative controls fail natively: wrong fill
  write way and wrong snoop lookup way. Neither is accepted as a positive run.
- Native executables/argv/cgroups and actual CPU12 affinity are observed;
  every child exits and is reaped. All 152 defines, six hard structural lint
  classes and 32 compile jobs remain. Duration **22.23 s**, peak RAM
  **2,747,482,112 bytes**, no swap/OOM.

Outer owner `ventium-way-tags-cache-oct14-r1.service`, invocation
`459ac1afb8a3478eae4b34f43927163c`, is terminal MainPID0/exit0. Its inner
scope is `8272ba177664446cbe375f592bae1df6`; the independent auditor matches
that scope's journal result as well as the outer owner. It rechecks 4,178
source/artifact pins and complete commands/fixtures/results.

| Evidence | SHA-256 |
| --- | --- |
| Cache `closed.json` | `bd205f6cb71ed206a6d3a41724bfa5ec4139e7f97031fa1be60f7daae0a28cbf` |
| Cache `audit.json` | `0674db78c180bf6901d2c91b2b164b1bdf789d774cce351644345fd035c67b86` |

These are binary simulation comparisons, not formal/X/Z proof or whole-core
differential acceptance. The existing canonical gate remains red.

## Inference probe and remaining work

`fpga/run_way_banked_tag_probe.py` launches the actual old/new **full L1**
through the exclusive Vivado launcher, with the unchanged 158-definition
hardware profile. It requires the 5,120-FF parent symptom and distributed RAM
with zero tag FFs in the candidate. Its two sequential syntheses have a
10-minute total cap, 8/2 GiB RAM/swap, 48 tasks, actual CPUs16–19 and a live
4 GiB disk floor. It does not place, route or generate a bitstream, and does
not convert artificial module I/O timing into CPU Fmax.

The owner `ventium-way-tags-probe-oct14-r1.service`, invocation
`0024195dba9e4ccfb6282139831f920a`, closes at **01:38:19 UTC**, MainPID0/exit0,
in **375.44 s**. Its single scope is `2cb3ec37c8c64716abe22111dd136204`.
Peak RAM is **4,648,337,408 bytes**, no swap/OOM or resource stop. The native
parent symptom is reproduced; the candidate infers **48 RAM64M8 macros per
way**, zero tag FFs. Macro totals and their 768 RAMD64E children are two views
of the same tag memory, not additive independent storage counts.

| Full-L1 OOC resource | Flattened parent | Way-banked candidate | Difference |
| --- | ---: | ---: | ---: |
| Total LUTs | 24,238 | 14,340 | -9,898 (**-40.84%**) |
| Logic LUTs | 22,190 | 11,524 | -10,666 |
| LUTRAM LUTs | 2,048 | 2,816 | +768 |
| Registers | 6,887 | 1,685 | -5,202 (**-75.53%**) |
| Tag payload FFs | 5,120 | 0 | -5,120 |
| BRAM / DSP | 0 / 0 | 0 / 0 | 0 |

These numbers include the actual L1 and its pair-return/bank-arbitration
hierarchy; they are not a miniature isolated RAM. Both use identical synthesis
options, part, 158 macros and helper modules. Port pruning and full-chip
cross-boundary optimization differ from an OOC run, so do not subtract this
9,898-LUT delta from the full-CPU utilization or claim a frequency gain.

`audit_way_banked_tag_probe.py` independently checks 4,388 pins, native closure,
actual affinity/resource observations, exact tag primitive inventories and
utilization rows. Closed receipt SHA-256:
`71cb057ab5247337f9e4a297096afeea825e3e6d8b1c857118305784128bbf25`.
Audit SHA-256:
`8c83d47cbee84baa1fc9b578743f30df04ed6a2c005e57cf3c94423e6f3036af`.
No Vivado family remains.

Still required: whole-core source transfer/differential tests, standard-suite acceptance, full synthesis
>=40 MHz, routing and physical Win95/Quake verification. The former worst
path still spans fetch/translation/cacheability/paired-store ACK/writeback;
way banking is not proof that this cross-module path is fixed.

Latest verified gameplay IPC is **0.48176594 total U+V**, older FP-repair
simulation model `c7b95b78`, cycles **1,100,065,237–1,200,065,237**
([evidence](../../fpga/FP_REPAIR_EXPORT.md)). This proposal is gameplay-unmeasured.
The existing FPGA still fails Doom startup on memory SMSW; no Doom FPS exists.
