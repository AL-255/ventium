# Bus cancellation and payload selection — October 11, 2026

**Private timing experiment; not a 40 MHz, canonical-gate or FPGA pass.**
The latest measured parent remains **26.55408 MHz**, below the required
40 MHz. Native synthesis and its source audit now pass; the original-clock
timing report is running. This change has no measured Fmax or gameplay result yet.

## Measured motivation and exact change

The [shift candidate's timing report](U_SHIFT_REGISTER_OPERANDS.md) shows a
134-level path from fetch address/length and access-fault handling through
fragment/request shaping, cache-response selection and the shared SRT input.
Its separate memory-capture path already limits the parent to about 28.09 MHz,
so [balanced SRT normalization](SRT_INPUT_NORMALIZATION.md) alone is insufficient.

[The exact-source recipe](../verif/issue_uv/prepare_bus_cancel_payload.py)
changes only `rtl/core/core_bus_driver.svh`. Paging miss/pending/permission
and synchronous-access/REP cancellation still suppress the request with the
same equations. They no longer clear unused direction/address/data/strobes.
Translation prepares the address independently of the late paging-fault
condition; A20 masks the physical payload even when invalid. State arms,
pre-squash observers and the final asynchronous-FP request hold are unchanged.
No clock, register, cycle, permission waiver or slow-mode fallback is added.

Parent header SHA-256:
`6bfa6c0e5f2e4e4e71535dd32c4334796e19facb60f7f97e488a617079587f8b`.
Candidate header SHA-256:
`e892403371c601c2e2c2660565fb8d4bf8ed7408efe3c0bf271015da63bf7ba1`.
The transform rejects drift and reverses to the exact parent header.

The intended benefit is removal of cancellation from payload-selection logic,
**not yet a measured timing improvement**. Invalid payload may differ. Issued
transactions, consumed responses and architectural/cycle behavior must not.
In particular, a low request signal alone is not a whole-system proof:
retained responses, fragment starts/aborts, A20, SMM, denied reads and faulting
writes need their own checks. The existing fragment-start equation retains
all miss/permission/access-fault/pending guards. No ACK equation is changed.

## Closed evidence

Evidence root: `/home/yukidama/external/tmp/ventium-bus-cancel-payload.Fzx7hUyD/`.

- Three host tests pass. The SMT proof uses an arbitrary pure translation
  function and all binary address/data/strobe/control inputs. Requests and
  pre-squash observations match unconditionally; issued payloads match when
  the request is valid. Deliberate permission, A20 and observer defects each
  produce a counterexample. This is a bus-tail algebra proof, not whole-RTL formal.
- `leaf-r1/`: the actual old/new source-extracted header tails pass **532,480
  native comparisons**, including **8,192 X/Z cases**, **12,117 accepted
  requests** and **490,011 inactive payload differences**. All three separately
  compiled defective variants fail their required assertions. The source
  state arms and translation function are abstracted in this leaf test.
  Native closure: **11.01 seconds**, invocation
  `06581fc3eb1d425a9f7986e17e1d0b32`, exit 0, unchanged pins.
  Receipt SHA-256:
  `2feab63fee6b91e621dfe46c9a0f300514ab44a1a4c9b0f7920f692210703d6d`.
- [The private core builder](../verif/issue_uv/build_bus_cancel_core.py)
  preserves all **195 source files except this one header**, all **150 UV-fast
  definitions**, and a private C++ harness/generated-header dependency. Four
  host admission tests pass. The guarded-32 build waits for the preceding
  canonical run's shared lock, then closes native 0 in **21.42 seconds**,
  invocation `3be50ec78f394d3b9ba002d000410db9`, with stable pins.
  Model SHA-256:
  `f2797f8c17cb6c7d8668432ae69dd42d427d25a3e3d3b3cd1452de8d6582b4bf`.
  Build receipt SHA-256:
  `8d0c627957725de1706e2f1ffa9e1321dded2c3cb016f09893c57cabc263cbbf`.

## Whole-core continuation and remaining acceptance

[The cold system runner](../verif/issue_uv/run_bus_cancel_system.py) builds
fixtures privately: `pxfrag`, `pxc04`, `pxc04e`, `pxc04f`, `pfault`,
`pfetchlim`, `prsmflush`, `a20test`, and `a20cmdtest`. It requires real guest
exit, precise-fault/wrap witnesses and identical parent/candidate full
functional/cycle streams at AXI latency 0/7. Eight fixtures use full QEMU
architectural comparison; `pfetchlim` retains its original non-differential
precise-fault contract. The private A20 fixture correction is described below.
Golden generation is serialized within the 32-worker matrix to avoid the
previous port-allocation race.
The first native matrix closes **FAIL** after 60.13 seconds, invocation
`94a3e5a9781c465893adea933c2745df`; its receipt and artifacts are retained.
Only `pfault` and `a20cmdtest` complete all four model/latency measurements,
with complete QEMU/parent comparisons and identical cycles. Five cases stop
on a **driver error**: architectural-register witnesses were incorrectly
applied to cycle-only records, which contain no GPR fields. Two original
fixtures also need their documented contracts respected: `pfetchlim` is an
existing non-differential, enforcement-witness gate (QEMU exits 135, not 133);
legacy `a20test` writes 0x02 to the 8042 output port, asserting active-low
reset as well as enabling A20. QEMU consequently does not reach the expected
exit with `-no-reboot`. The pinned QEMU `hw/input/pckbd.c` explicitly requests
reset when output-port bit 0 is clear. None is evidence of a candidate RTL
regression, but none can count as a completed candidate check either.
R1 receipt SHA-256:
`51600d9a7a7b6bf48f9615d013602882453b193d88f41ce8e4b3bb8f0bd38a81`.
This is not SMM or reset-injection coverage.

The failed R1 driver is preserved in commit `93ad4eb4` (SHA-256
`9f55bc0096abc49173cbb8492b12dc08c9a767da895c52cf9ae2b389bd1c8507`).
The corrected R2 driver does not overwrite that evidence. It checks GPR
witnesses only in architectural traces, retains all cycle records separately,
and privately changes the A20 fixture's `0x02` to `0x03` to deassert reset.
No production RTL or canonical fixture is changed by these driver repairs.
Six host contract tests cover these fixes and reject bad fault counts, PCs
and error codes.

| Closed candidate checks | Scope | Result |
| --- | --- | --- |
| `system-r2` | 9 cold fixtures, 36 model/latency measurements, 31,748 architectural records | PASS; full parent state/cycles identical; 3,068 candidate V retirements |
| `fp-r1/matrix` | 72 paged/relocated FP fixtures, 288 measurements, 78,048 architectural records | PASS; full QEMU and parent comparisons; paired/early-FP witnesses required |
| `smm-r1` | Original `psmm` and `prsmflush_smm`, 8 measurements, 51,160 architectural records | PASS; complete parent state/cycles/save-map identical; guest-triggered SMI/RSM |
| `rep-smi-r1` | Original `prepsmi.S` with `PREP_SMI_MOVS`, 4 measurements, 652 architectural records | PASS; exact source-owner ARM/CANCEL boundary and saved REP state |

SMM tests require independent free-running QEMU exit and the P5 save-map,
restored context and remapped-fetch witnesses. They are **not QEMU
single-step differential checks**, reset-injection sweeps, or the legacy
linear-I-cache way-placement probe. The REP test uses the unchanged
`prepsmi-rtl-selfcheck.py`: at latency 7, source ARM is cycle 8,323 and CANCEL
is 8,324; SMM/RSM preserve ECX=1, EDI=`fee00304`, ESI=`2404`, then the final
iteration reaches ECX=0, EDI=`fee00308`, ESI=`2408`. There is no snapshot or
architectural-state injection.

Closed receipts (SHA-256), respectively:

- `07f44ca4673a5873fe04d9b465f21ae5ac8bbe235e2152534392104ee094101c`
- `13865bba04d7d696f6383cdad8ede73526ebc96230445438121c2f063b8fcc14`
- `ff8d31a40fa992769ed61edfd88c4b50ae72ecea7cbb58bc4468265d0ae27de8`
- `e681ad477ccb4adbb5dbff7f160c12650849cb29aa9b740d8fefd24fe66a334f`

The unchanged canonical gate closes **FAIL**, native exit 2, after **407.77
seconds**, invocation `1647f78e57e94b22bbdf559c7683f7c9`. All 20 complete
canonical cycle streams match the measured parent; inputs remain unchanged.
No masks, goldens or bands were adjusted. The owned continuation closes its
complete **108-program /80,800-record** same-input comparison successfully,
invocation `1dbef6d0edcb43f6b9a2522757294853`. Its overall result remains red
because the canonical gate failed; this is not an infrastructure failure or
a reason to rerun the completed comparisons.

[The independent auditor](../verif/issue_uv/audit_bus_cancel_core.py) reopens
all four matrices' **161,608 architectural and 161,608 cycle records**, save
maps, native commands/exits, the full QEMU comparisons where applicable, all
20 canonical cycle streams and the 108-program replay. It checks the one
header delta across all 195 source files and the exact closed process owners.
Audit SHA-256:
`1c6738e1a201bb9367d5180e1c45110dc7ed36e6ea2f1601daa6c3e6249f564a`.

[The PC builder](build_bus_cancel_soc.py) now reconstructs only that header
delta on the measured shift candidate, with all 154 native definitions,
posted-16 transport and all 102 shared directed RTL sources unchanged.
[The exporter](freeze_bus_cancel_rk_candidate.py) retains the original
40 MHz core /100 MHz PL clocks and 156 hardware definitions. Eight admission
tests reject profile drift, lost fast features, unreviewed source deltas,
unreviewed aliases and replaced input files. These are preparation checks,
not an actual new synthesis or FPGA result.

The PC build closes native 0 in **51.73 seconds**, invocation
`0f8b662e8d434c27b1ae04b0daf021b4`, with stable inputs and a verified private
harness/header dependency. Model SHA-256:
`c9d73a0643a759e411f2dbfcecd2425df247349b42e68a4b01eb3ff4edc6cb47`.
The 98 inherited full-PC structural warnings are unchanged, not waived away.

Preparation R1 stops before writing any exported payload: its alias policy
did not yet admit three existing passive directed-harness headers. Those
headers are also dependencies of the parent model, not new simulation
behavior. The failed receipt remains in `prepare-r1/`; its exporter is
preserved in commit `655637f0`, SHA-256
`2c759305eefb1aa1342bb0a2986745518fadb9e5e98c9395fca28f38db96e75d`.
R2 admits only their three exact aliases and rejects redirected targets.
No core or PC model is rebuilt for that correction.

Preparation R2 closes successfully, invocation
`7a59449270c54ff0a3e0ffc7903d896c`. The independent source audit rechecks
**315,365 input pins**, the exact single header delta and all 102 shared
directed RTL files. Strict CPU-hierarchy lint passes all six hard structural
classes under all 156 hardware definitions in **3.61 seconds**; this does
not erase the separate full-PC warning debt. Frozen manifest SHA-256:
`9fe0c951a57d41826a4383055d3bbbf63cb6b7bb16936a400be9741792fb9536`.
Preparation receipt SHA-256:
`2c9dd75d5a3808bd9f4fb97238e54029c6e9b37e7e818639872434b713eb9cb3`.

Both unchanged short CoreMark seed disks now close successfully under
`ventium-v-carry-cm10-bus-cancel-oct11.service`, invocation
`50b8a7337aab47e3b34ee59eedc9bc37`. Both match reference CRCs and the parent's
exact clocks: **4,767,218** for the performance seed and **4,753,406** for
validation. Native runs exit 0 in 276.38 and 197.54 seconds; actual V retirements
are **1,055,307** and **1,054,254**. The independent audit reopens both complete
console results, native child receipts, affinity, model/source/media pins and
resource counters. There is no OOM event. Its receipt SHA-256 is
`ad88a482173e5d59c8d7eb8baa69a10585ed1f5fab4b8187ee8a689e659c7dda`.
These short runs are not full-duration scores or the original standard-suite
acceptance. There is **zero measured benchmark-cycle gain** from this
timing-only transformation.

Queue
`ventium-bus-cancel-timing-queue-oct11.service`, invocation
`e2ea91192dff4082bb6379825c59503a`, observes these exact owners; it does not
restart an observation timeout. It then permits one exclusive 45-minute
Vivado synthesis and a separate 15-minute original-clock reporting run,
with the existing **8 GiB RAM /6 GiB swap**, **4 GiB disk stop floor** and
host-memory reserves unchanged. No placement, routing or deployment is
started by this queue. The synthesis controller starts under
`ventium-bus-cancel-synth-oct11.service`, invocation
`3cb3b697de204e66a54aadaf4de7f8cc`. Its launcher starts at **10:07:29 UTC**;
the single native Vivado family is observed at **10:07:32 UTC**, scope
`98ffa801966d4fb3931758a9272af25f`, with the requested hard limits verified.
It closes native zero at **10:39:20 UTC** in **1,911.18 seconds** (31.85 minutes),
with unchanged inputs, no resource-stop/controller failure and no OOM. Peak
scope usage is 8,589,733,888 bytes RAM and 178,536,448 bytes swap, within the
unchanged hard caps. The independent audit checks **315,582 input pins**, the
actual 156 definitions and 148 native `read_verilog` files, the single intended
payload delta, native completion, DCP and resource receipts.

| Synthesis utilization | Shift parent | Bus-payload candidate |
| --- | ---: | ---: |
| CLB LUTs | 184,962 | 185,708 |
| CLB registers | 54,646 | 54,612 |
| BRAM tiles | 277.5 | 277.5 |
| DSPs | 47 | 47 |

This is a **746-LUT increase (+0.40%)**, not an area reduction. There are zero
errors, 1,564 warnings and one critical warning in the audited logs. The critical
warning is the inherited generated PS8 XDC clock-on-unknown-pin warning; it is
retained, not waived. Original-clock coverage and structural timing qualification
still belong to the following report stage.

Closed synthesis receipt SHA-256:
`361a468493a0cb252b9954ee7c3969bc48ecd59c919799cbfc933b7c7c281cae`.
Independent synthesis audit SHA-256:
`dc8ce76caad65d9efc505c08c0fce21fe25d20859c2cb12ba504d1f65b35de1e`.
DCP SHA-256:
`26b3ffc95c25b1ac211827eed1d5561710b3f32e4f969d0af8cf0d3ff9583577`.

The timing-report controller is now active under
`ventium-bus-cancel-clock-oct11.service`, invocation
`73ef37243d0f48ed802a8a2dd4af84d9`. **26.55408 MHz remains the only measured
candidate-line Fmax** until those original-clock reports close. A successful
synthesis alone is not a 40 MHz pass. The independently reproduced generic-read
overread and private follow-on correction are documented in
[FRAGMENT_READ_PAYLOAD.md](FRAGMENT_READ_PAYLOAD.md); that correction is not
in this completed DCP.

Full downstream/core verification, actual mapped timing, the original standard
suite and physical FPGA Win95/Quake validation remain required. The existing
canonical gate remains **FAIL**; a parent/candidate match cannot turn it green.
Neither this change nor SRT/ALU sharing has been merged into production RTL.

Disk safety: four exact inactive SRT precompiled-header caches were losslessly
archived and member-compared before removal, recovering **286,179,117 bytes**.
`compiler-recovery-r1/` contains member hashes, archive hashes and recovery
commands. Binaries, sources, ordinary headers, objects and logs are retained;
all protected input pins remain stable. No broad directory deletion was used.

Further closed-artifact recovery archives six generated core precompiled
headers (**484,036,608 bytes recovered**), 20 already-closed private Win95
guest disks (**707,706,880 bytes**) and 49 September profiler intermediates
(**1,300,877,312 bytes**). Each archive is losslessly member-compared and its
source hashes rechecked before removing the exact originals. Recovery commands
and hashes are in `closed-storage-recovery-r1/`, `closed-storage-recovery-r2/`
and `closed-profiler-recovery-r1/`. R1 completes its three compiler-cache
archives, then stops before touching any guest because an old systemd unit
has already been collected. R2 additionally requires the guest's actual
child-wait/closed-disk receipt, a terminal or absent owner, and no live process
or open file. Live zero-C1 runs, seed media, logs, captures, source and simulator
binaries are untouched. Total new recovery is **2,492,620,800 bytes**, entirely
recoverable; this restores the unchanged synthesis disk-admission reserve.

The guard's additional growth-based check requires **7,208,493,056 bytes**
free: the earlier matched-profile run consumed 1,456,762,880 bytes, and the
guard reserves twice that growth above its 4 GiB stop floor. Merely exceeding
6 GiB is insufficient. Before Vivado launch, `admission-reserve-recovery/`
therefore losslessly archives this already-compiled PC model's two PCH files
and one old derived `normalized.vcap`, recovering another **577,052,672 bytes**.
The original raw capture and existing movies are retained. Hashes, member
comparisons and exact restore commands are preserved; the native benchmark
binary and all protected input pins are untouched. Recovery receipt SHA-256:
`6160bb2b13a7f66d08f77e873a418dc548a83a4b80fb89a496f1cacbee745354`.
The growth-based admission check and all runtime floors remain unchanged.

A read-only board check at this stage succeeds over SSH: root has about
262 MiB free, `/dev/shm` about 320 MiB, and no `ao486d` process is found.
Existing zero-C1 staging and the Win95 seed remain present. Nothing is
programmed or removed on the board; this is readiness information only.

Verified gameplay baseline: **0.51030715 total U+V IPC**, simulated model
`2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates this experiment,
which has no gameplay measurement, new bitstream or physical-board pass.
