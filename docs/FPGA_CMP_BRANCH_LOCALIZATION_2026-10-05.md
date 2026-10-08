# FPGA memory-CMP/conditional-branch localization — 2026-10-05 UTC

The requested **40MHz** production Quake timedemo remains **unpassed**.
The October7 `6659e0c5` UV/fast cold run reaches rendering, then returns to DOS
without a timedemo result. The original CMP/JP64 microtest passes, but the
full workload still fails; see the final entries for the new fault evidence.
A complete15fps recording of a separate37.5MHz cold timedemo is now retrieved
and verified, documented below. These are private cold diagnostics, not patched production Quake,
save-state repairs, or acceptance substitutes. The original control runs did
not change the installed FPGA image, clock, RTL, production BIOS or disk.
On October6 the preserved debug-only observer image was deployed, as recorded
below; it does not implement a processor fix. Production BIOS/disk and RTL
remain unchanged by this investigation.

Current verified active-timedemo IPC: **0.165995778 primary/U-counter IPC**
(not total U+V IPC and not evidence of U-only execution), retirement-observer image
`53f129e9`, measured **37.499869764MHz**,127 qualified intervals spanning cycles
**8,721,490,845–19,169,282,165**, demo frames37–898. This is the closed R4
aggregate with gaps between qualified groups, not an every-cycle full-demo
score or40MHz qualification. The earlier closed R3 aggregate is below.
The latest deployed observer image `ef01263f` (unchanged `6659e0c5` CPU logic)
has **no gameplay measurement**;
the above hardware baseline predates it. Original CMP/JP64 now passes all
64 cases at measured 39.999836260 MHz, without breakpoints or stepping, with
an independently audited fast-paired retirement witness. This is a microtest
pass, not full-workload acceptance; the production timedemo remains pending.
UV dual issue and fast
pipeline are now mandatory acceptance requirements, including dynamic test
evidence; a slow/U-only passing control does not qualify a repair. Earlier
`5a0561fc`, diagnostic-only `48288e83` and other results remain recorded
chronologically below.
The older0.42633263 simulation baseline(build `5c2491f3`, cycles
7,099,999,637–7,199,999,637) predates this FPGA candidate. The PS PL reference
is not the core frequency; actual core counter/time measurements are used.

## Hardware results

All controls retain the original full prelude, CPL3 mappings, congruent caller,
memory service and general exception logger. They use the same conditional
branch location `14565`, except the explicitly labelled JMP control.

| Control | Relevant change | Hardware result |
| --- | --- | --- |
| Memory-left CMP/JP | Original diagnostic ROM | #PF14/error4 at `00a7:14566`, FLAGS `887`, CR2 `493c6488`; two cases complete |
| Memory CMP/JMP | JP `7a13` → same-length JMP `eb13`; synthetic returns all1 | 64 cases pass |
| Original CMP/JP, separately stepped | Identical ROM; STEP suppresses U/V pairing | First three pairs correct; ordinary paired release fails on case4 at `14566`, FLAGS `46` |
| OR EDI,[EDX+10]/JP | Only ROM opcode at `14562`: `39` → `0b` | 64 cases pass; flags `2,2,86,46` |
| CMP EDI,[EDX+10]/JP | Opcode `39` → `3b`; first two memory inputs1 →3 | 64 cases pass; flags `93,93,86,46` |
| Reversed CMP/JP, overflow discriminator | Only prepared-memory immediate high byte `9d7`: `00` → `80` relative to the passing reversed-CMP ROM | 64 cases pass; QEMU/model flags `93,93,46,887` |
| Original CMP/JP, bad-boundary BP | Identical ROM; breakpoint only at wrong EIP `14566`, no STEP | Actual bad architectural EIP captured **before** ADC or #PF |

OR writes EDI; reversed CMP does not. Their data/arithmetic and warm histories
differ from the original control. They narrow the investigation but do not
prove a memory-left-only defect, forwarding failure, descriptor corruption,
synthesis bug, or physical timing cause.

## Coherent pre-fault bad-boundary capture

The existing debugger parks at **CS:a7/EIP14566**, with last primary retirement
**14562**. Hidden CS/DS/SS/ES bases are **10000000**; CPL is3. State was read
before manual HALT or late forensic reset:

```
EAX=00000043 ECX=00000108 EDX=00efe6cc EBX=002c403c
ESP=000e07f8 EBP=00000000 ESI=00000002 EDI=80000000
FLAGS=00000887 CR0=80000011 CR2=00000000 CR3=0007e000
CS=00a7 SS=DS=ES=00af FS=GS=0000
```

Actual aligned 16 MiB physical-RAM capture checks the original code
`397a107a138b4c241039`, two completed cases, caller3/checksum `9fff`, third-case
memory0/EDI80000000, original mappings, and an entirely zero 104-byte exception
record. JP has PF1 and must target **1457a**; even a correct not-taken branch
would go to **14567**, never14566. The later ordinary fault's displaced ADC
address independently reconstructs CR2 `493c6488`.

The breakpoint does not name intended V PC14565. The debugger's paired-V
boundary check would normally compare `14562+3=14565`, not14566. However,
other debugger-history perturbations are not excluded. The PC ring exposes
primary U retirement only: **no actual retained V descriptor, length, condition
bits, next-PC mux input, or FPGA cache contents had been read in this original
capture**. The later observer capture is described separately below. Its legacy
`lin=` selector-times16 display is wrong for this protected-mode hidden base;
use the captured hidden descriptor, not that display.

## October6 observer capture: preserved defect, inactive older packet

The deployed observer image reproduces the original wrong architectural EIP
**14566**, FLAGS887, CR2zero, last primary retirement14562 and
count2/caller3/checksum9fff before ADC/#PF. The original JP ROM, code bytes,
guest mappings and operands are unchanged; there is no STEP, intended-V
breakpoint, guest-memory repair or processor RTL fix. Reset and parked scans
both satisfy the signature, metadata, two-read coherence and selector-restore
protocol. Native invocation `4b1cc1fe7f9c4690a75728bf282c0dae` closes0 and
the independent host audit verifies all42 exported files and the architectural
and physical-RAM context.

The338-bit physical scan is **not the failing packet**. Retained owner EIP is
**14558**, all eight ACTIVE copies are0 and the retained PAIR bit is1. The
decoded known fields match the earlier `CMP [EDX+8],ECX; JNE +1d` in the
captured instruction bytes: U length low bits3, memory displacement8,
memory-left CMP; V length low bits2, condition5 and displacement1d. Unlisted
optimized fields, including length bit3, remain unknown. The failed CMP at
14562 instead uses displacement10 and JP conditionA/displacement13. Do not
attribute the retained V condition/length/target to that later CMP.

In the frozen RTL, ACTIVE0 selects the live `u_d/v_d` descriptors rather than
the retained packet (`core.sv:6155`). Retention is engaged when a new memory
request must wait (`core.sv:7473`). The parked observation therefore narrows
the missing evidence to the live/immediate-response execution path; it does
not by itself prove which dynamic packet selected the bad PC on the preceding
edge. No stale-packet-consumption, decoder, cache or next-PC root cause is
claimed. The OR and reversed-overflow passing controls are rerun on the
observer image below; they do not make this older packet attributable to the
failing CMP.

Evidence:
`ventium-private-observer-boundary.cj7i9A/exception-log-XEIuht-export/closed-capture.sha256`,
SHA-256 `c179ded78eec8103afe366b9c5aad730cc5e3c1272bab5e024e66def6c0b2aee`;
independent `audit-result.json` and `closed-audit.sha256` (SHA-256
`a7c6d0e6325a69becba638d3df8ab68c3a43e4c0a5567138e3a6927e3e027f51`).
This qualifies a coherent retained-state read at the reproduced private fault,
not a complete internal-state dump, ISA gate or completed Quake timedemo.

Both original passing controls also complete64 cases on the same observer
image: count64/caller64/checksumd5540, normal AL42/exit-HLT context and an
entirely zero104-byte exception record. Each closes native0/controller0,
retains the original ROM and production pins, and passes coherent reset and
terminal scans before late forensic reset. No STEP or breakpoint is used.
The independent host consumer verifies39 exported files per run and their
separate native invocations:

| Observer-image control | Native invocation | Closed-capture SHA-256 |
| --- | --- | --- |
| OR/JP | `917b3fd4d0db41fbbfdebb86f2dee47e` | `785625108da3f5ff8692d3d13baf56fd82e0efdef33aae1f3501b8fc50d4e6b0` |
| Reversed CMP/JP, overflow discriminator | `95699908015643d3a2e13e5af36c54cc` | `405af9f51b09efad2b0af9980645e3cc4c05db750bd2f1b050086496e4c10358` |

Artifacts are under `ventium-private-observer-controls.BFWmEY/`; the independent
consumer prints `PASS_PRIVATE_OBSERVER_CONTROLS_ONLY` and its sealed audit is
`closed-audit.sha256`, SHA-256
`4f9b8be7673ccd4420a615747ac462af07c2222cf792f7dbed0e660d5129c98d`.
The observer preserves the failing-case/passing-control distinction in these
tests. It is still not a processor repair or standard-suite acceptance.

To bound board RAM-disk usage, only the older closed `9loTuZ` run and its
duplicate export are removed after checking all35 sealed files, the exact
closed native invocation and the kept VHD seed. This recovers53,415,936 bytes;
full recoverable evidence remains at
`ventium-private-reversecmp-overflow.o9SjbO/exception-log-9loTuZ-export` on
the host. Production media, the original rollback BIN and the new observer
captures remain untouched.

## October6 direct retirement capture: correct live fields, D/Q discrepancy

The qualified partial retirement observer was programmed without a CPU RTL,
placement, original-route, clock or production-media change. Native bitgen
closes0/pins0 and its independent raw-BIN consumer passes; BIN SHA-256 is
`53f129e9e1c4e36bcd342fb38e4e9abd11edc55f1e2e0971b6a2a41292ad4001`.
The actual deployment closes0, preserves both rollback images and all eight
production pins, and measures **39.999870539 MHz** over5.000124108 seconds
with reset held and zero retirements. It is not gameplay or STA acceptance.
Deployment seal:
`ventium-retire-deploy.kmw81J/native-export/closed-deployment.sha256`, SHA-256
`4d91ec67e2eccf7dc7347c54f885ead9b2fc78acfe8a5101f900f11ff4d527cc`.
The independent host deployment/clock arithmetic audit passes. An initial
recursive retrieval returns1 on the unreadable empty once-marker directory;
every sealed file and raw BIN is recovered and hash-checked independently,
and a separate named-manifest retrieval closes0. No deployment is retried.

The original failing JP ROM again parks **before** ADC/#PF at case2,
CSa7/EIP14566/FLAGS887/CR2zero, primary retirement14562. This run uses no
STEP, intended-V breakpoint or guest-memory repair. Both observer banks have
correct signatures, coherent double scans and selector restoration; the
actual registered primary PC, next-PC and PF match halted architecture.

| Directly sampled field | Observed value |
| --- | --- |
| Architectural primary / next PC | `14562` / **`14566`** |
| Prior EIP-D known value / known mask | `14547` / `ffffffdf`; bit5 **UNKNOWN** |
| Prior original EIP enable | 1 |
| Prior live U/V length low3 | 3 / 2; bit3 unknown |
| Prior live V condition / displacement | A / `13` |
| Prior ACTIVE / state | 0 / 28 |
| Prior PF-D / architectural PF-Q | 1 / 1 |
| Legacy retained owner / eight ACTIVE copies | `14558` / all0 |

The sampled branch fields match the actual `CMP [EDX+10],EDI; JP +13`,
and ACTIVE0 selects live inputs in the frozen RTL. The prior known EIP-D
bits differ from committed EIP on **bit0**, despite sampled enable1.
Do not choose a value for missing bit5: the partial word is not a complete
EIP-D value. These observations narrow the next checks to branch/next-PC
selection, commit, and observer edge validity; they do **not** prove a root
cause or exclude transient/path-dependent sampling. The passing controls and
correct-edge comparisons on this new observer are recorded immediately below.

Native invocation `c6e3110a23c94a268ed7d43512861b63` and controller both
close0. The independent host consumer verifies44 exported files, all input
pins, native identity, original code/mappings/operands, zero exception record,
all150 retirement storage bits (149 known), and all338 legacy physical bits.
Capture:
`ventium-private-masked-retire-boundary.okShyC/exception-log-WVpK5F-export/closed-capture.sha256`,
SHA-256 `52da7989fccd07c624d92d73a0665289be6b831e96c6b138adff736fa77d8f4c`.
Host audit seal `closed-audit.sha256`, SHA-256
`a31682257d0941f598b9f7ee9ab58e4d344bc83c9a727e3bc9d33d6906e8eb3f`.
Guest is held in reset after late forensic capture; no production Quake or
Vivado worker is running. No CPU repair or timedemo/movie completion claimed.

Both existing passing controls subsequently complete64 cases on the partial
retirement image without BP/STEP or exceptions: count64/caller64/checksumd5540,
AL42/normal exit-HLT. Coherent dual-bank reset and terminal scans pass, and
native/controller both close0. The independent consumers verify41 exported
files per control, exact ROM/input/native pins and full16MiB RAM:

| Partial-retirement image control | Native invocation | Closed-capture SHA-256 |
| --- | --- | --- |
| OR/JP | `34edbd2705994325845233ed7c6fbd9f` | `2368ffbab79e7c22cbb9454afc1b98f2d43f84368d7b0925459410ce0979cfd9` |
| Reversed CMP/JP, overflow discriminator | `2a339b5f1493457991b67ecc266a2fc7` | `e344b7c4de75d16dc5360878c19f62c74fb40156435b6535ca78841802eac3e6` |

Host recovery root: `ventium-private-retire-controls.W2hm8V`.
Independent audit seals: OR `closed-or-audit.sha256` SHA-256
`7fe2105bd21726cf87b5fdcb28677c6ff20fb18cbaffa6c01dfd5d1961d66dbe`;
reverse `closed-reverse-audit.sha256` SHA-256
`d7654cee64b3f21d9a1c6335a8f152a34a5c43d714563b39e1ea4506bc9cf7f0`.
An mDNS lookup fails once; the existing authenticated board session confirms
its address10.0.0.214, and subsequent named captures use that address.

Three additional cold runs capture **correct architectural successors**, not
the intended V instruction14565, without STEP or payload changes. The original
ROM stops at its first NT boundary14567/case0; OR and reversed-CMP controls
stop at their first taken target1457a/case2. Each native/controller closes0,
and its independent consumer checks43 sealed files, original mappings/code/
operands, zero exception record and both raw scan banks. All four sampled
edges below have primary14562, state28, ACTIVE0, enable1 and live U/V low
lengths3/2, V conditionA/displacement13. Unknown EIP-D bit5 is excluded from
every comparison, never guessed; length bit3 remains unobserved.

| Edge | PF-D / PF-Q | EIP-D known value | Architectural next PC | Known D/Q XOR |
| --- | --- | --- | --- | --- |
| Original CMP/JP, first correct NT | 0 / 0 | `14547` | `14567` | 0 |
| OR/JP, first correct taken | 1 / 1 | `1455a` | `1457a` | 0 |
| Reversed CMP/JP, first correct taken | 1 / 1 | `1455a` | `1457a` | 0 |
| Original CMP/JP, reproduced bad edge | 1 / 1 | `14547` | **`14566`** | **1** |

Known D/Q XOR is `(sampled_known_D ^ actual_Q) & ffffffdf`, not a
reconstructed full D word. The first NT retained owner is1455d; both taken
controls and the failing edge retain the older14558 packet with all ACTIVE
copies0. The observer can distinguish NT and taken inputs in these controls,
so a universal readback bit0 mapping/alignment error is not an explanation
supported by these samples. Path-dependent sampling, unobserved inputs and
transients remain possible; these checks do **not** qualify observer STA or
prove a forwarding, mux, enable, synthesis or silicon timing root cause.

Recovery root: `ventium-private-retire-boundaries.po0KZG`.

| Correct-edge capture leaf | Native invocation | Closed-capture SHA-256 |
| --- | --- | --- |
| `WBbyr6` (original NT) | `7aa7da843ff4479e83e096bcad4d1264` | `48cbc708ba17a33b229ea84f143a67ff9630a81d8c265424df38791a5f4b8844` |
| `5BewYN` (OR taken) | `8eb26738b65e446eadf7067f29b4e096` | `7b54b330edbb75475d87f0f2d4a793b29f8a94145fe64f7947dcc428756bbd46` |
| `z6vDs8` (reversed CMP taken) | `9f7e6471004341a3980f3721d39b08ea` | `a7b07a7632cd9aa627949e57d290ef85e9aa4587634d5030e24438fa83ad294b` |

Their independent seals are `closed-original-audit.sha256`
`da4a401907f67f2676a9d82290ed4843f4ed497bec68149e7227e56f49652150`,
`closed-or-audit.sha256`
`ab02acb5db5ddc7338977bff52c2d1f63d8dc65c6d31b1ae275a67ab4a9367ba`,
and `closed-reverse-audit.sha256`
`a2e8222a493830b84f182324ce7e1de012538fb258353301ba22ea0992028381`.
The copied arithmetic decoder test initially lacks its fake-reader helper;
after copying the unchanged helper it passes256 synthetic checks. That fixture
failure is not a hardware/ISA finding, and synthetic checks are not acceptance.

For these bounded captures, admission reserves127MB RAM-disk free space: a
measured <64MiB run+export footprint plus >63MiB spare. The native service has
RuntimeMaxSec60/MemoryMax384M/TasksMax32 and a30-second daemon window; no
verification timeout, memory cap, payload or processor throughput rule is
relaxed. Production Quake timedemo/movie and candidate gameplay IPC remain
unmeasured/pending; the control ladder is not the standard suite.

## October6 mapped branch-selector check

A read-only query of the actually deployed routed checkpoint closes native0/
input-pins0: eight roots,134 primitive cells and818 pins over three mapped
levels. It performs no synthesis, placement, routing, constraint change,
checkpoint write, bitgen or deployment. The independent consumer checks
actual LUT INITs and pin connectivity, then passes **1,024** combinations of
five effective flag cutpoints,16 condition codes and conditional/unconditional
selection against the ISA Jcc truth table. For effective JP/conditionA, the
mapped selector uses the effective PF cutpoint as expected.

This clears the tested selector truth table, **not upstream flag production**.
The branch's effective-PF producer is distinct from architectural PF-D.
Captured architectural PF-D/PF-Q1 therefore does not establish the branch's
forwarded PF value on the failed edge. Its upstream flag-write/shift controls
and parity source remain unobserved. Net display names are not authoritative:
one alias named `eflags[0]` is physically driven by architectural PF register
bit2. The consumer uses native driver identities, not that alias spelling.

The first native query closes1/pins0 because the diagnostic script applies
`get_nets -of_objects` to a net instead of querying its native segments.
Its source and rejected receipt are retained. The corrected query closes0.
The initial independent consumer then rejects14 **unconnected, unused CARRY8
outputs**; a separately named revision checks their exact identities and
requires one driver for every connected pin and every input. It closes0;
neither script failure is a CPU finding. No dynamic flag value, complete
fanin-cone proof, STA sign-off, processor repair or timedemo acceptance follows
from this static cutpoint check.

Evidence: `ventium-retire-nextpc-fanin-r2.vHEVSU/closed-mapped-fanin.sha256`,
SHA-256 `c9e2a41053d8a9b9ea7f2199dec490016ab07d5a0d654fe7e659027dcbedeab8`;
independent closure `closed-independent-consumer.sha256`, SHA-256
`4dce652724c6f1353b92812a2bbc1445e2ede5cab46dc6346a2e96cf76140c86`.
The rejected query is separately sealed under
`ventium-retire-nextpc-fanin.KyXRO9/closed-rejected-driver-query.sha256`,
SHA-256 `4fee34b975b7023c05aa64e5bdc17bf37a587d6e4830be4fd4cbb2fcab1a07e5`.

The bounded upstream extension closes native0/pins0:22 roots,276 cells,
1,756 pins and the same three mapped levels. All134 earlier cell functions and
818 earlier pins match literally. Its independent consumer passes the same
1,024 Jcc cases plus128 parity-forwarding cutpoint cases: non-shift U flag
writes select the ALU-PF cutpoint; otherwise old PF is retained; nonzero shifts
select even parity of the two shift-parity groups. This is not a proof of the
ALU-PF source's value or any unobserved decode controls at the hardware edge.
No checkpoint or FPGA image is changed. Query closure:
`ventium-retire-forward-fanin.no5t64/closed-mapped-fanin.sha256`, SHA-256
`35031107b77666ba320dc226e58834f67f8bfb5a43ae2308ff730a7e1653c043`;
independent closure SHA-256
`c7f80706b8f5a99dbfa0382d4dea4fe5ecdbdbf663f31f6057187205d10b5bdc`.

## October6 clock/cadence discriminator — not a lower-frequency fix

Two cold runs use the **same original JP diagnostic ROM, seed, full prelude,
observer BIN and native executable**, with no BP/STEP, pairing suppression,
RAM repair or RTL change. The existing audited PS clock presets are used;
each launcher restores `iopll-100m`/40MHz after its service closes. The lower
clock is strictly a private discriminator, not a replacement implementation
frequency or timedemo acceptance.

| Measured core clock | Native / controller exit | Result |
| --- | --- | --- |
| **37.499884255 MHz** | 0 / 0 | All64 cases; caller64/checksumd5540, normal AL42/exit-HLT, no exception |
| **39.999873899 MHz** | 0 / **1** | Same #PF14/error4 at CSa7/EIP14566, FLAGS887, CR2 `493c6488`; count2/caller3/checksum9fff |

Clock samples independently check five-second monotonic-time/cycle arithmetic,
100 held-reset guards and zero retirements. They are not IPC measurements.
Host consumers verify all45/46 sealed files respectively, original ROM/code/
mappings, native identity, coherent dual-bank reset/terminal scans and16MiB
RAM. The 40MHz consumer's integrity exit0 **does not turn its controller1 or
CPU failure into a pass**. The full exception record and displaced-ADC CR2
arithmetic are checked independently. Both clock-restoration receipts match
the 40MHz preset; production-media pins and rollback images are preserved.

The failure is now experimentally **clock/cadence-sensitive**. This does not
yet distinguish physical capture timing from a memory-response/ownership race:
changing the PS reference also changes the cadence relative to memory service.
A subsequent correct original-ROM taken-edge capture at the lower clock is
described below. No timing sign-off, root cause or processor fix is claimed.

Recovery root: `ventium-private-clock-discriminator.feXIXN`.
37MHz leaf `93HxOv`, native `6bdb4f05e72b4980a40930d5cd95e3da`, capture SHA-256
`c19027a79e93e2175e6b91afd67fdc7ec32e57ac488c388975fb14dcc19d110c`.
40MHz leaf `l2w0qN`, native `bd976743f2124e69977152b11c1fae42`, capture SHA-256
`1f8c6f27c997e577eef1325e916de43095d0549abd0e812c37d9b29731d6f4ce`.
Independent closure `closed-clock-discriminator.sha256`, SHA-256
`c512a2db28e0ef1f142505ce0a983993be0bf02726c7d3c0a09cc5e2013f826a`.

Before these controls, only the closed `WBbyr6`/`5BewYN` board runs and their
duplicate exports are removed, after checking all43 files per host archive,
exact native invocations and live board source pins. This recovers111,009,792
bytes. Complete recoverable host evidence remains under
`ventium-private-retire-boundaries.po0KZG`; both fault captures, the latest
reversed-CMP edge, seed, production media and firmware are retained.

### Original taken-edge capture at37.5MHz: same live path

At measured **37.499881010 MHz**, the original JP ROM parks at case2,
CSa7/EIP1457a/FLAGS887/CR2zero, primary retirement14562, without STEP or
intended-V breakpoint. Its known EIP-D value is1455a, maskffffffdf; the known
D/Q XOR is0. Prior ACTIVE0/CE1/state28, live U/V low lengths3/2, conditionA/
displacement13 and PF-D/Q1/1 match the corresponding fields of the failed
40MHz edge. The retained owner is14558 and all eight ACTIVE copies are0,
also matching that failure. Both runs have the same case2 operands, original
code and mappings, and caller3/checksum9fff. EIP-D bit5 and length bit3 remain
unknown in both.

Thus passing merely by switching to the retained-packet path is **not supported
by these samples**. Unobserved decode/forwarding inputs, response phase,
transients, replica capture timing and observer timing remain unresolved;
matching ACTIVE/live fields does not prove identical full-cycle waveforms.
The launcher restores the 40MHz preset after native0/controller0. The
independent host consumer verifies47 sealed files, source/native/image pins,
all149 known retirement bits,338 legacy bits, architectural context, zero
exception record and complete16MiB RAM.

Recovery root `ventium-private-clock-taken-boundary.h6Gf3e`; leaf `2iOFH6`,
native `56366081759c49599294689b9d807b09`, capture SHA-256
`073a45c38149a78a53ce8cf425afedfa6c16bf7ccb863b5e35ecc96a479fc749`.
Independent closure SHA-256
`84f1db3eb09c4ecba1c75184360e25b88014d18f3e8923f922c0987e07ecf591`.
Before this capture, only the closed host-archived `93HxOv` and `z6vDs8` board
runs and their duplicate exports are removed, recovering110,362,624 bytes;
their full host archives remain. The original and newly reproduced 40MHz
faults, seed, media and firmware remain intact. This is not a 40MHz repair,
standard-suite pass, gameplay IPC measurement or completed Quake timedemo.

### Read-only directed path query

The deployed routed checkpoint is queried without optimization, routing,
constraint changes, checkpoint writes, bitgen or deployment. Native closes
0/pins0. A data-only consumer checks all24 max/min queries through effective-PF
or V-branch-taken to EIP bits0/2/3/4, including the subset starting at the32
EIP registers. It checks actual traversed resource rows, not replay of Vivado's
misleading collection-formatted `Command` header. The bit4 destination is
FDSE/S, while bits0/2/3 are FDRE/R; the earlier incomplete query's mistaken
reset-pin assumption closes native1/pins0 and is not a processor finding.

The EIP-rooted max paths through effective PF have47.614–47.984ns data delay
and110 logic levels under the saved25ns/40MHz constraint. Roughly78% of that
delay is routing. Their unregistered chain includes fetch-window selection,
decode, address/translation, memory-return/flags, V condition and next-PC.
Changing EIP sources are therefore not absent from the long static cone.
**These are slow-corner static paths, not a measured Fmax, proof that the
complete path is sensitized by case2, or proof of the failure's root cause.**
The measured board frequencies remain the37.499884/39.999874MHz controls above;
the memory-response race alternative is still open.

Recovery root `ventium-retire-directed-paths-r2.3nNLyv`; native seal SHA-256
`c017cf581923e1693fa3f4dc08d5f54988d127685e0baf104c40db38160d8b68`;
independent seal SHA-256
`8d3ffe55787ebf82ca6a78b6c77131cb371c2e5348fd9c25f70baed5ba11da23`.
The separate data-only cleanup audit validates all six host recovery archives,
four closed cleanup receipts and exact deletion sets. Cleanup seal SHA-256
`61a11889fb963953d225861ffe8ac96c282d8a7ba803f6d14a1b1dc73e331d9c`;
it does not infer the current live board state from historical receipts.

### Selected EIP commit-law check

A data-only audit of the saved native pin query checks EIP bits0/2/3/4.
All four share the same clock and enable; bits0/2/3 are FDRE with common R,
and bit4 is FDSE with S driven by that same management reset buffer. Pin
inversions are0. The installed vendor FDRE/FDSE/glbl functional models are
then simulated with the exact four primitive types/INITs, the captured known
D inputs and prior primary PC. No Vivado, RTL, FPGA or clock change occurs.

All20 functional-model cases pass (five actual captures × all four common
CE/reset combinations). All four correct-edge captures agree with CE1/reset0.
For the failing40MHz capture, none of the three settled logical outcomes agrees
with the actual Q, even if its sampled enable is allowed to be either value:

| Selected bits0/2/3/4 only (`mask=1d`) | Value |
| --- | --- |
| Hold prior primary PC | `00` |
| Enabled load of sampled known D | `05` |
| Common reset/set | `10` |
| Actual failed-edge Q | **`04`** |

This excludes a **settled, uniform logical** hold/reset explanation under the
PRE/Q alignment assumption. It does not exclude physical skew, transient
inputs, unobserved controls or invalid observer-edge alignment, and is not
observer STA or a silicon timing proof. Bit5 is never reconstructed; the
other28 EIP bits are outside this primitive simulation's scope.

Recovery root `ventium-eip-commit-law.GWizoG`; actual audit exit0. Two early
pre-simulation failures (aliased path and wrong manifest filename) remain
recorded as exit1. The initial in-flight seal is rejected because it hashes
stdout before closure; the separate post-close consumer validates the actual
exit/log/result and pins, then seals all25 final files. Final seal
`closed-actual-eip-commit-law.sha256` SHA-256:
`b1977c72305dcfcf7fbda0baec23275d4ef088cd6a7daca6fcbc7f7bd89f5df9`.
No root cause,40MHz repair or workload acceptance is claimed.

### Odd-target discriminator (2026-10-06 UTC)

A new **private diagnostic** keeps memory-left CMP at14562 and JP at14565,
but relocates the common taken epilogue from1457a to **1457b**. Thus both
valid successors, fallthrough14567 and taken1457b, have bit0=1. Eight branch
relative immediates become old+1; the identical13-byte epilogue moves one byte
and an unexecuted NOP occupies1457a. All opcodes/data operands and instruction
addresses within the172-byte body stay unchanged. **The payload bytes are not all
unchanged:**164 of172 match the parent JP ROM; eight relative immediates differ,
four in each of the134/38-byte subranges. No production Quake/BIOS/VHD, CPU RTL,
FPGA image or pairing policy is patched.

ROM SHA-256:
`f42858ee4a653d1818ebda8747aa70c2356ad4c13ce8c3edeb7402990cbb2050`.
Pinned Pentium QEMU checks all64 actual branch edges and original CMP flags
2/2/887/46, then returns AL42/debug-exit133 with count64, caller64,
checksumd5540 and a zero exception record. QEMU/reference wrapper exit0 is
not FPGA acceptance.

The cached assertion-enabled, real-reset-edge model matrix checks seeds1–32,
AXI latencies0/3/7/13 and alternating response-gap schedules. Initial matrix
exit1 is retained: seven natives hit the64MiB file cap (SIGXFSZ), and concurrent
consumers also had resource failures. Only those seven natives are rerun,
with the same seeds, assertions and180-second limits and a128MiB file cap;
closed-stream consumers are regraded serially. Final results are **32 native0,
27 consumer0, five consumer3**. All2048 architectural cases and their raw
CMP/JP descriptors, flags and request/retirement joins pass. Seeds5/8/14/30/31
lack the additional warm retained-predicted-T/actual-NT conjunction; they are
coverage exclusions, **not five full passes or architectural failures**.
Matrix/wrapper exit remains3. All179 frozen source inputs match before/after.

The post-close consumer validates actual exit receipts and all32 JSON reports,
then seals366 model/golden/source files. Model seal
`closed-model-evidence.sha256` SHA-256:
`05bca0de49e3e68715f460674c72b12fc1be62a8ffbce08424f5454639f99a65`.
Earlier inherited one-opcode provenance is preserved, not used as the child's
change count. R2 corrects the eight changes; the board's R3 metadata also fixes
the inherited runtime target/limits. ROM and closed QEMU/model streams do not
change. A pre-upload wrong-offset assertion is retained and corrected before
any launch.

On unchanged observer image53f129e9 at measured **39.999872115MHz**, the
natural private run misses the1457b breakpoint during case2. Native closes0;
controller/launcher close1, correctly rejecting the diagnostic. It reaches
the private verifier's error exit **CS8/EIPf0258/EAXee**, not an exception:
CR2=0 and the104-byte exception record is all-zero. Physical RAM checks
count2/caller3/checksum9fff, memory0, actual BIOS/client/caller code and original
mappings. The primary-PC ring shows **00a7:14562 → 00a7:14567**, rather than
the reference's1457b. The actual flags at that CMP edge are **not observed**
in this terminal capture; expected model flags887 cannot substitute for them.
This new result does not support treating the earlier error as merely an
illegal-address/bit0 alignment problem, but altered branch immediates and code
geometry still prevent a single-variable physical root-cause claim.

All45 exported files are independently hash-checked and the terminal audit
closes0. Invocation `dac2d6c4157445b2bdeb15bc825eba9c`; capture seal SHA-256:
`39841d72020b7d2b859893f18249cc0b3fc150c608b14f7a22a6f96a67361a1f`.
Recovery root `ventium-private-target-lsb.UXIa4w`, export
`exception-log-PJpuRD-export`. Board-only copies of the fully archived37.5MHz
correct-edge run2iOFH6 and this terminal control are pruned after exact file,
invocation, native-status and source checks, recovering55.5MB and54.5MB.
Their host archives remain recoverable; both earlier40MHz fault captures,
VHD seed, production media and firmware are preserved.

The held-reset preflight measures a zero **retirement delta**, not an absolute
zero counter: the board PMU retains its older epoch. The private preparer
requires reset hold, non-frozen reset CR0 and stable retirements before/after
disarming; it neither clears the PMU, releases execution nor changes clocks.
The40MHz preset is restored after closure. No40MHz production timedemo,
CPU repair, new gameplay IPC or standard-suite pass is claimed here.

#### Direct wrong-fallthrough scan: useful partial run, not a pass

A separate controller alternates successor breakpoints14567/14570 through the
early NT path; it never steps or sets a breakpoint at intended V14565. This
perturbs warm history. Its next14567 stop is **actual case2**, not the loop's
expected case1: the controller correctly rejects the scalar mismatch and
closes1 before its normal export. The launcher explicitly stops the daemon;
the cleared post-stop systemd status is **not a natural native0**. No guest
restart or successful sweep is inferred, and the missed expected case1 stop
remains an ungraded coverage/control issue.

The saved coherent scan nevertheless captures the wanted wrong edge:

| Actual case2 retirement observation | Value |
| --- | --- |
| CS / primary PC / architectural next PC | `a7 / 14562 / 14567` |
| Architectural FLAGS / memory / EDI | `887 / 0 / 80000000` |
| Previous state / EIP CE / ACTIVE | `28 / 1 / 0` |
| Live U/V length low3bits / V condition / relative offset | `3 / 2 / A / 14` |
| Flags-register PF D / Q | `1 / 1` |
| Known EIP D / mask / known D–Q XOR | `14547 / ffffffdf / 0` |
| Reference taken destination | **`1457b`** |

EIP-D bit5 and both length bit3s remain **UNKNOWN**. PF-D is the input of
`eflags_reg[2]`, **not a direct observation of effective PF at the branch LUT**.
The retained packet still belongs to14558, with all eight ACTIVE copies0;
it is not the packet owning CMP14562. The live-path selection and actual
registered next PC are observed, but a settled effective branch condition
is not. These limits also apply to the earlier40MHz wrong-boundary capture.

Both wrong results fit the same selected-bit pattern: for bits0/2/3/4, old
target1457a / NT14567 / actual14566 are`1a / 05 / 04`; new target1457b /
NT14567 / actual14567 are`1b / 05 / 05`. In both, bit0 agrees with the taken
destination while bits2/3/4 agree with NT. This is a **bitwise fit**, not proof
of a transient mixed PC, wrong adder base, stale flags, observer alignment or
physical timing. Moving the target's low bit can conceal the illegal boundary
without correcting the branch result; it is not a usable processor repair.

The original breakpoint halt survives the daemon stop. A separately named
recovery verifies current architecture equals the saved pre-stop state,
HALTED stays set and retirements do not advance across the aligned16MiB RAM
read. It checks actual count2/caller3/checksum9fff, zero exception record,
original inputs/code/caller/mappings, and exports36 closed files. Physical DDR
is still **not a cache dump**. Recovery's first attempts retain a pre-transfer
file-not-found and an overly strict reset-hold guard; neither releases or
restarts the guest. The successful recovery and independent audit close0.

Native invocation `a52859ffb4c142bc838f3d61c33cb9ba`; measured held-reset
admission clock **39.999874147MHz**. Partial export seal SHA-256:
`80588780c87b40916d10e25b5360136ef6a44cb96ae66cdf18ed7cd93d241272`.
Recovery directory `ventium-private-target-lsb.UXIa4w/fallthrough-r1/`;
`exception-log-MH5a4f-interrupted-export` preserves the actual scans and RAM.
The guest remains breakpoint-halted, the daemon is stopped, and no new
bitstream, RTL fix or40MHz workload acceptance is claimed.

The final post-close follow-up seal checks the model seal again and validates
both hardware result classifications, then hashes514 regular files, including
all failed attempts and both new host exports. `closed-followup.sha256`:
`c9e78596f069710571956a2dc0de257fa200b0711423af551bc658616a854979`.
Actual sealing exit0; no still-running output is included. Next localization
is the effective branch-flag/next-PC selection cone, not a change to CMP's
architectural arithmetic. Any eventual repair must preserve general paired
execution and pass differential gates plus the complete standard suite;
none is implemented or declared complete by these diagnostic controls.

### Cold recording startup — capture-client issue, not a CPU finding

A separate unchanged-media cold diagnostic at measured37.499883540MHz stops
after the recorder reports `seq=1 128x3 pixels=360`. The requested mode is
320x200; metadata validation precedes the existing `--skip-unmatched` filter.
The producer exits2 and the monitor exits1; transport closes0 with only a
16-byte header. The guest service is explicitly stopped, so its cleared
post-stop systemd status is **not a natural native exit0**. No gameplay,
completed timedemo, full movie or processor pass is inferred. The monitor
restores the40MHz preset and holds guest reset after preserving state/RAM.
All regular board files, including the original cloned disk and16MiB RAM,
are independently hash-checked on the host against closure SHA-256
`55317a7dc90cd7969a324e9db8f5b2c4a3464c7ebc72e5a5b17b3642b955a2e8`,
under `ventium-fpga40-capture.VMIAgs/quake-clock37.S0lmbK/failed-start-board`.
Only those two large board copies are then removed; the recovery copies,
production seed, firmware and earlier40MHz CPU-fault captures remain.

The generic capture client now distinguishes typed invalid metadata. Only
before its first accepted requested-mode frame, with explicit dimensions and
`--skip-unmatched`, it may discard a positive, bounded **non-requested**
startup raster. It neither drains nor emits that invalid payload. Requested
320x200 corruption, impossible metadata, subsequent metadata errors, timeouts
and consumer loss remain fatal. A retry deadline prevents endless malformed
startup handling. All26 mock/signal tests pass, native0 in0.011s, including
actual mocked MMIO validation/no-drain, mode/opt-in restrictions, post-first-
frame failure, deadline, whole-record SIGUSR1 and broken-pipe cases.
Source SHA-256 `426f793fb280133fd35ea19ed37e9229dd4f54badcc6562ac0176ddad6cffa0d`;
test SHA-256 `17e908a8276a45e67f5f2301ac6f4096305b51d751d882a9bda30ad20e029e54`.
There is no RTL, guest-code, color, dimension or frame-rate change. A fresh
cold diagnostic is being retried separately; this software test is not a
hardware movie or timedemo pass, and the40MHz CPU defect remains open.

The next cold run uses the same image and original production ROM/media at
measured**37.499881997MHz**. Its recorder passes the initial partial raster
and720x400 text frames, then exits2 on a completed`0x0/pixels0` interval.
The monitor now retains that recording failure while allowing the unchanged
guest to finish. Native invocation`93599532b19246aba13ab148f20018e6` closes
normally(code1/status0/MainPID0), with `done: x86_polls=76800128` at its600-second
service-loop budget. The monitor exits1 because capture failed, restores the
40MHz preset and holds guest reset. **Recording failure is not relabelled as
success, and this is not40MHz qualification.**

The closed FAT-console checker independently reads the original held disk
descriptor. It finds a **fresh969-frame/demo1 result:288.3 guest seconds,
3.4 printed fps**, after a new/changed-byte-extent playback marker; the
465-byte baseline has no result. It checks all retained result lines, error
patterns, numeric rounding, FAT membership and unchanged disk hash. The helper
exits0 with `CLOSED_CONSOLE_EVIDENCE_VALIDATED_NOT_FPGA_ACCEPTANCE`; hardware,
native closure and cold-reset evidence remain separate. A live read also
observes playback active at865 frames before the flag later clears. The short
performance sample occurs afterward, so its0.138444 IPC is **not claimed as
verified timedemo/gameplay IPC**. At that point candidate timedemo IPC was
unmeasured; the following cold run supplies the active interval reported above.

Recovery root`ventium-fpga40-capture.VMIAgs/quake-clock37-r2.uBQifa`;
board closure SHA-256
`d96f87860062c9494ab2127f81b53a3e5eba024c8b072e3cffd267509651ff16`;
closed disk SHA-256
`55a47e20f5fd9107598b4b8eb9e982b5a7b49dcad387021977b7609e7d14c73e`.
Independent closed-console seal SHA-256
`37a505b531f3e012b81d2af223314cf76796ccef301eaa4168b5c660d69ccfff`.

The frozen recorder RTL can legitimately complete an empty interval when
VSYNC runs with no active video. A second generic client revision permits
only the exactall-zero case under the same pre-first-target/explicit-mode/
opt-in/deadline restrictions. Partial-zero metadata, requested-mode corruption
and any metadata error after the first accepted frame stay fatal. All28
mock/signal tests pass(native0,0.011s). Client SHA-256
`8ff672d0af63ecc18b8519b6e7fdfe2f1137c9284b7eeb99867b28de0012b6a3`;
test SHA-256 `f86045a0a052a87481b7effba9a662607e786a064f92d58223a8dd38e79bd035`.
An actual post-run capture returns320x200/64,000 pixels, sequence7 and CRC
`8a424917`. Lossless PPM→PNG conversion preserves RGB bytes exactly(SHA-256
`b3bbd75eaae4263b3323eca109b188b57b70ec6df11269bb02e3312f200ee777`).
This shows the capture interface works beyond startup, not full temporal
coverage or capture of all game frames. No sync-polarity defect is established;
no recorder RTL, CPU RTL, guest payload or colors are changed.

### Cold recording R3: active IPC, later empty scanout

The next original-media cold run uses the same diagnostic image at measured
37.499876871MHz. The recorder emits16 valid320x200 frames, then exits2 on
sequence24's exact`0x0/pixels0` interval. This is **not a complete movie**;
transport exit0 does not make producer exit2 successful. The unchanged guest
continues under native invocation`f1e825a40f774603b2565f9073f001fa` and later
closes normally(code1/status0/MainPID0); its watcher exits1 for recording
failure and restores40MHz while holding guest reset.
Read-only engine witnesses bracket the independent-checked first sample:
demo active1, the same nonzero demo file, frames40→50, no debug freeze,
HALTREQ, breakpoint or single-step;77,287,244 cycles and11,372,892 retirements.
Recovery root`ventium-fpga40-capture.VMIAgs/quake-clock37-r3.N7gmzr`.
This first sample is not a full-run weighted IPC estimate. The sealed closed
log supplies127 independent-qualified active intervals spanning cycles
10,079,905,963–20,519,678,252 and frames40–900, with gaps between groups.
They account for9,820,997,166 cycles/1,631,830,793 retirements, giving weighted
**0.166157343 IPC** at37.499867698MHz. Startup, post-demo activity and incoherent
or out-of-range intervals are excluded; this is not every-cycle full-demo
accounting. The independent closed-disk consumer confirms a fresh969-frame
demo1 result,288.2 guest seconds/3.4 printed fps, and no retained error line.
Board closure SHA-256`5da1f7bda35929863381260f790b5fbad34d6521a8bb221aa725cb85594e1a7a`;
independent results seal`576b69bd2b0c5f14047e4ab1f63645c20c07b46fbec31dc58a3da97973f980ee`.
The first recursive retrieval fails on root-private file permissions; after
granting group read access only within this closed diagnostic, all sealed
regular files are recovered and hash-checked. Failed retrieval/audit logs
remain; no partial retrieval is counted as a complete archive. Only the closed
board VHD and16MiB RAM copy are removed after host recovery checks; full host
copies, all metadata, production media, firmware and fault captures remain.

The generic client is consequently revised to skip an **exact all-zero empty
scanout**, with explicit dimensions and`--skip-unmatched`, before or after
accepted capture starts. The frozen recorder can end any VSYNC interval with
zero active pixels; zero stale BRAM bytes are drained or emitted. No black
placeholder is manufactured. The wait has a consecutive-gap deadline, also
applied to subsequent capture waits; only a complete requested-mode image
resets it. Nonempty post-start malformed metadata, partial-zero metadata,
requested-mode corruption, timeouts and transport faults remain failures.
All33 mock/signal tests pass(native0,0.012s), including late empty intervals,
deadline reset/non-reset cases, no payload drain and opt-in restrictions.
Client SHA-256`9b60a741522dc6519ace852d4e338fc09cbcafd12d6e3c5167cdd1532984c8cd`;
test SHA-256`baf075b243b02bb23f381e244b9b02e090789a4f2211736b7265e7336a4c0ad4`.
This is a host/PS capture change, not a CPU, recorder RTL or guest fix.

The fresh cold R4 recording uses this client and the same image/media at
37.499878045MHz, native invocation`7cacf13de33b43c382cc1266fd4808be`.
It resumes after the empty-video interval and collects changing320x200 frames.
At the first independent IPC audit it has41 qualified intervals,3,173,050,804
cycles/527,442,756 retirements, giving an initial0.166225752 sample.
A1,385-record in-flight prefix passes CRC/geometry/order checks; its last
complete frame(sequence1514) is Quake gameplay. PPM→PNG decoded RGB remains
byte-exact(SHA-256`b269b7d7eeb54785740c7de3c2a6719bfa55f5e3a7cdbcb06b894e77f4fb85ea`).
The R4 movie helpers retain frozen179-file ancestry separately from the new
runtime client. Their bounded synthetic normalizer/FFV1/RGB-round-trip and
corrupt-record/deadline checks pass. Host proof seal SHA-256
`58d44455cbedc318fe8d986b6999584879aadf6e41e956f6831ff8e3e1663a78`.
Recovery root`ventium-fpga40-capture.VMIAgs/quake-clock37-r4.xUgDDO`.
At that point, the in-flight prefix and host fixtures were **not a completed
movie or timedemo acceptance**. The subsequent closure is below.

### Completed cold recording R4

The same unchanged CPU image and production BIOS/disk complete the cold run.
The native daemon completes naturally; the recorder and watcher also close
successfully with code1/status0/MainPID0, using their original invocation
identities. The recorder receives SIGUSR1
only after coherent post-playback witnesses(demo inactive/file0 and host
framecount>1000); its final whole-record count is6,505. The guest continues
unchanged to its600-second service-loop deadline. The watcher holds reset and
restores40MHz only after all owners close. No snapshot, STEP, breakpoint,
guest patch, exception suppression or new FPGA image is introduced.

The closed FAT-console consumer independently confirms a freshdemo1 result:
**969 frames/288.3 guest seconds/3.4 printed fps**, with no retained error line.
Console SHA-256`0bd2c8c255906a837bf39f2476670f0bd04d2d1f63771eb2a89d174d3fb738a1`;
closed disk SHA-256`013a0cd844aabc5d86cb8728d0c187e7f0f7fdd426e98df70e113ca5291491ed`.
All sealed board files, including16MiB RAM, are recovered and hash-checked;
native/archive closure is distinct from the console helper's deliberately
limited`CLOSED_CONSOLE_EVIDENCE_VALIDATED_NOT_FPGA_ACCEPTANCE` marker.
Board seal SHA-256`41da535c69ded8d954c4b301efb1e40d8b0cbeca39802a59981231026da1eadd`.
The independent closed log qualifies127 playback intervals:
9,828,716,788 cycles/1,631,525,491 retirements =**0.165995778 IPC**.
The exact window/groups and source-log hash are in`active-intervals.closed.json`.

Host transport exits0; raw416,554,196-byte stream SHA-256
`e3ce32ddfca73154f7073d4b7569e3615aa29e38e0fae3879995cee79e9eafbb`.
The root-authored closure binds actual producer identity/count and clearly
labels host size/hash/transport observations as relayed attestations, not
board-local hashing of the host file. Closure SHA-256
`926a7d190be1b53b78b4c788980e60bec9b9672843c1c015db75c017c73de7ac`.
Normalization validates every record's CRC, dimensions and ordered timestamps,
preserves the raw quota32768 and emits a6505-record header; no partial tail
exists. An initial encoding rejects an aliased output path at receipt binding;
using canonical scratch paths succeeds without changing validation or pixels.

All three movies preserve all6505 accepted records at320x200 and15fps:

| Format | Bytes | Verification |
| --- | ---: | --- |
| FFV1 RGB MKV | 412,217,678 | full decoded RGB hash matches capture |
| Lossless H.264 RGB MP4 | 24,709,792 | same decoded RGB sequence/count |
| GIF | 5,802,150 | same decoded RGB sequence/count;433.67s duration |

Common decoded RGB SHA-256
`ebd9b0945c08d505df4d218b1e281293129818b93f49abf3228c76ccc6a06dc5`.
There is no gamma/brightness/contrast, resize, crop, record removal or
duplication. The GIF uses the source's at-most256 RGB332 colours and lossless
LZW/delta encoding, not another colour-quantization pass. Its centisecond
delay rounding differs from6505/15 by less than0.01s. A directRGB8 trial
changes decoded colours and is rejected; the two-pass exact palette succeeds.
MP4/GIF initially hit the512MiB virtual-address limit during thread creation;
bounded allocator arenas(`MALLOC_ARENA_MAX=2`) succeed at the **same** limit,
with two codec threads, one filter thread and600-second stage deadlines.
These encoding jobs are not OOM-killed; no FPGA rebuild or hardware restart
is involved.

Viewing files live in the recovery root's`movie/` directory as
`quake-fpga-37p5MHz-full-capture-15fps.{mp4,gif}`. MP4 SHA-256
`62ee215ac54a65bc22d86bca890c9d3de24120a2d3e000ba20876e60586310bf`;
GIF SHA-256`7bb0f4b07add8a562a65fc5a934eb61079b12a7feb4601b2845e70904fca7c8a`.
The verified GIF replaces the README hero; its earlier version is backed up
in this recovery root. Hardware clock and guest-reported fps are explicitly
labelled, separate from15fps presentation. This records the entire diagnostic
session around timedemo playback, **not every physical scanout or engine
frame**: the single-BRAM recorder inherently has drain/re-arm gaps and empty
scanouts have no emitted payload. Complete bookended recording does not
discharge the40MHz branch defect or full standard-suite acceptance.

Final movie-evidence seal (`closed-full-movie-evidence.sha256`) SHA-256:
`9e4b92fc7d5ef4c95e80ea2e93069f1a79d2c6f01fba622718b39505bf9ad535`.
Recovery root: `ventium-fpga40-capture.VMIAgs/quake-clock37-r4.xUgDDO`.
After byte comparison and matching SHA-256, only the failed-path attempt's
duplicate `normalized/normalized.vcap` (416,554,196 bytes) was removed.
The retained `normalized-r2/normalized.vcap` has SHA-256
`4b3369b30e37bf7c6edbe8b6de55cebab813a27ac8cce92900dd0308a6bc6a0e`.
Raw capture, accepted normalized stream, failed-attempt logs and receipts,
all movies, and board recovery remain available.

## Model/reference verification

Pinned QEMU Pentium independently checks all64 actual post-ALU states and JP
destinations for both new opcode controls, then reaches normal AL42 debug-exit
**133**, zero exception record, count64/caller64/checksum `d5540`.

Each new opcode control also ran32 bounded, assertion-enabled cached-model
jobs in parallel: randomized reset seeds1–32, AXI latency0/3/7/13, alternating
response gaps, one model thread per job. The separately corrected harness
establishes a real asynchronous reset edge and retains four reset clocks;
it never forces internal state or disables assertions. All179 frozen inputs
and native/model/source pins match before and after.

For **each** control, **32 native exits are0**, all64 architectural cases,
original prelude/seam pairs, qualified memory responses, exact raw211-bit U/V
packets, GPRs, flags and next PCs check correctly. **27 consumers return0**;
seeds **5,8,14,30,31 return3** because the additional warm retained
predicted-taken/actual-not-taken coverage conjunction is missing. These are
architectural passes with missing coverage, **not32 complete gate passes**.
The complete matrix returns3 and its enclosing verification wrapper returns1.
No SVA stops or native timeouts occurred. These models do not reproduce the
FPGA's actual XPM contents, clock crossing, physical mapping or delays.

The reversed-CMP builder's initial byte-offset receipt assertion failed even
though assembled bytes were correct. That exit1 is retained. A separately
named R2 receipt corrects offset `9c0` to actual `9c5` without changing or
reassembling the ROM; R2 exits0. Do not erase or relabel failed receipts.

## Sealed evidence

All paths below are under `/home/yukidama/external/tmp/` and must be preserved.
Each capture has an independent read-only audit, exact native invocation,
source/ROM/production pins, closed service receipts and full RAM evidence.

| Artifact directory | Native invocation | Capture files | Closed-capture manifest SHA-256 |
| --- | --- | ---: | --- |
| `ventium-private-memor-jp.FhwQES` | `cc9e4d485dc048d79e71ff3ddcc902b8` | 35 | `f2beb8891a561523536387c04b663be65a9efbe730c6d95ef8753327047ba9ae` |
| `ventium-private-reversecmp-jp.7IPNOW` | `be543a699ba54e59bceab1965f989f1c` | 35 | `ec4cd446f020f36d0eb07b1f949f3d333b5c2e9fda84e64b7e84e456895cd9b4` |
| `ventium-private-jp-bad-boundary.oE0Zzd` | `6a4c8cd84c114501a6918e9e3cc5c67d` | 37 | `a59bb0703d29097ab0d5d6e57f4a3375998e26a77d77f39371290030d5fce541` |
| `ventium-private-reversecmp-overflow.o9SjbO` | `ceac17fecb284b4dbb732d265e5ac3e8` | 35 | `c4b44755d1ec63eac318843160190102eac9018b90f236af452761c6d5415cec` |

ROM SHA-256: OR `c34416d37d2080927e6b88e6133405020507d1edd97f56e6df65ae75b5ff7bb4`;
reversed CMP `8c143eb2230400771976ec151c84a50eabcf4cba5909c8c3adb6a3a2563fdb13`;
original JP `e6b20263852628770d3d9de0e8834681a7da844cd2f88ece2a7bd8ec95195f8a`.
Overflow-control ROM:
`d3b796de70876c79c540a2982c7745a5b1b48bf19ed3390a5aac6e4ad630640b`.
Those four pre-observer captures used bitstream bin
`30b0178eb924eb2914bda6300f7ef3f3bef233b48d821ef77bf452349f8beefb`.

At the last capture all native workers and model matrices were closed; the
guest was held in SoC reset after the coherent state/RAM capture. No Vivado
instance was launched for these controls. Board root has very little free
space; diagnostics belong in bounded `/dev/shm` leaves, with sealed exports
retrieved to the external filesystem before pruning anything.

## Next discriminators and fix requirements

The additional one-immediate-byte overflow discriminator is now closed and
independently audited0. It retains every instruction location, all172 parent
payload bytes, JP NT/NT/T/T outcomes and GPR schedules; last-two memory inputs
become80000000. Pinned QEMU and the frozen model check actual flags
`93,93,46,887` for64 cases. Hardware reaches normal64/caller64/checksumd5540
with zero exception record and no BP/STEP. These checks weaken overflow alone
as an explanation; **per-case hardware FLAGS were not scanned**. Its32-job
matrix has the same32 native0,27 consumer0/five coverage-only3 results as the
other new controls. No production input or FPGA image changes.

The deployed **core observation ring is not an instruction/read-beat trace**.
Despite inherited comments, the frozen `ventium_l1_axi.sv:1569` assignment
captures only acknowledged **writes to VGA text page B8000–B8FFF**, with store
data. `rk_ao486_system_pl.v:314` wires that tap, not the available AXI-master
read-beat tap. The ring's populated-count output is unconnected; its reader
always returns the requested128 entries. A ring clear resets head/count but
does not erase BRAM. These private ROMs make no VGA writes, so their exported
`frozen-core-ring.txt` files show stale pre-control text stores, not current
branch or memory-service activity. Do not derive a current FSM state, cache
return, or instruction-byte identity from them. The independent capture audits
do not use those stale entries as correctness evidence. PC retirement ring and
coherent architectural scans are separate, still useful observations.

Similarly, outer AXI counters use global `rst`, **not** guest reset or debug
clear (`rk_ao486_system_pl.v:113`). Their large absolute values cannot be
charged to one private cold run. Performance analysis needs qualified interval
deltas and wrap handling, not mixed counter epochs.

## Private retained-packet observer preparation

Read-only native queries now bind the saved routed checkpoint to actual
physical FF pins. The checkpoint's companion binary is exactly the installed
`30b0178e...` image; checkpoint SHA-256 is
`86ebc6ec9abe6b0bb7dbc93dd7b7d321e0b183b5abc25dd68962c30edb5f50e3`.
The initial packet inventory finds158 U,139 V,32 owner-EIP, eight replicated
active and one pair FF: **338 raw physical bits**, not complete optimized
211-bit RTL structs. Never invent missing fields as zero or infer physical
selector bits from LUT/net aliases bearing similar names.

The R5 binding query closes native0/input-pins0, recording all32 management
read-data FFs, the seven original selector FFs and their replicas, and the
registered ARREADY FF. The R2 control-cone query also closes0/0. Its actual
LUT INITs prove the ARREADY **D input** is `R_IDLE && ARVALID`; the registered
ARREADY **Q output** is too late for a read-data D-input override. All32 old
read-data drivers each feed exactly their one management data FF; no CPU
functional sink is disconnected by the proposed insertion point.

A private observer plan uses181 LUTs, changes only those32 debug-data D inputs,
and adds observation loads to retained FF outputs. Selectors96/97 carry a new
signature/size header;98–108 expose the338 raw bits with an explicit physical
pin catalogue;109–127 return zero. Selectors0–95 and every non-2B0 CSR read
must remain transparent. Original FF clock, enable, reset and CPU control
connections are untouched. These selectors are **not available on the board
yet**, and this is not a functional processor repair.

Finite logic checks pass10,016 primitive truth cases,45,568 scan-bank cases,
1,048,576 address/selector/acceptance cases, and6,144 read-phase cases. A
separate consumer checks the actual native control cone over131,072 cases,
all eight external ARVALID source combinations, and32 exclusive old-data
sinks. These are observer-contract checks, not core differential gates or
timedemo acceptance. Two earlier offline consumer failures (record-kind and
active-register spelling) are retained; the separately named R3 plan passes.
The control-cone route inventory also explicitly has **ACTIVE count0** because
its pattern omitted `_q`; the eight active FFs remain bound by the independent
packet inventory. That route inventory alone is not a complete ECO proof.

Routing must preserve original branches on newly tapped, partially routed
nets: `route_design -preserve` alone protects only completed routes. Use
appropriate `FIXED_ROUTE` sections and verify physical preservation, as
documented by [AMD's route command reference](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/route_design).
Only the32 old debug-data routes may be replaced; they have no other sink.
The private construction stage is bounded and produces no bitstream or board
deployment. Placement/routing, unchanged original-function/route evidence,
and private hardware controls are still required before using a new observer.

Sealed query artifacts under the external temporary root:
`ventium-debugscan-binding-r5.Zoz4qk` (closed manifest SHA-256
`f69dd3db4bf2317568516ace49af5d189764707545bebc6189676bac8de9e314`);
`ventium-debugscan-controlcone-r2.bo8imT` (
`f25637a50f81985f45db0f3b3b35db7eac674c2aa996f7cbe54211f7ce394c9b`);
`ventium-debugscan-contract.siewqF` (closed logic manifest
`ea1097c482bf158a959daf5b5b1b121628a540bf83d9f5e6b8d6b996a82007d2`).
Failed native query receipts are preserved separately; their checkpoints and
source pins remain unchanged. All native invocations use the sole-instance
guard, explicit external TMPDIR, resident-memory/swap/task limits and deadlines.

Construction attempts R1/R2 fail safely on native `LOCK_PINS` handling; R3–R5
reach their deadlines during route-guard preparation, **before creating any
observer cell or reconnecting any input**. All close native1/input-pins0 and
produce no new checkpoint, bitstream or deployment. R5 records390 sources and
1,884 affected old LUTs; its source-binding and lock-collection stages take
75.2s and242.2s respectively. These are tool-script failures, not DUT failures.
The original checkpoint and installed board image remain unchanged.

A separately checked constant-free observer graph removes132 GND/VCC input
edges by LUT cofactoring without changing the181-LUT bank or its338-bit
catalogue. It passes7,024 local exhaustive cases,45,568 bank cases and4,096
random envelope comparisons against the original plan. It avoids adding
loads to chip-global constant nets. Artifact:
`ventium-debugscan-cofactor.axp8n9/checks/`, native-plan SHA-256
`721a0795fcbba0f798dcc4801e28b8f6c8c75871ddaed889e052441284a3b590`.
The R6 constructor batches native property reads and identical per-cell
constraints; a mock-native check covers1,884 cells and rejects an incompatible
pre-existing lock without mutation. Its540s outer/510s inner deadline also
expires: native1/input-pins0, no added cell, reconnect, checkpoint or deployment.
Its mapping collection takes378.1s;1,350 guard rows are written before the
deadline. The mock did not reproduce native large-dictionary access overhead, so
this attempt is not evidence of a faster implementation.

A separate **read-only** native cost query closes0/0 in41.7s. Looking up50
native Vivado handles in the large cell dictionary and grouping them costs
2,016ms, versus0ms at millisecond resolution for grouping ordinary names.
A291-pin batch BEL query takes1ms;
the ordinary pin's `BEL` property is blank and **cannot** substitute for the
actual BEL-pin relation. Preserve exact native bindings; optimize bookkeeping
representations rather than weakening route guards. Sealed query:
`ventium-debugscan-query-cost.iWjcup/closed-query.sha256`.

The follow-up R3 native query closes0/0 in45.3s and corrects the initial
attribution: **large dictionary access**, not native handles themselves,
dominates these loops. Fifty cached REF lookups cost1,121ms with native
property elements and1,105ms after flattening them to ordinary strings.
The same fifty REF lookups through Tcl arrays, grouping their native handles,
and the native batch-property query each take0ms at millisecond resolution;
exact counts are checked. R2 retains native1/input-pins0 after an attempted
escaped-name lookup resolves no cells; it is not a passed complete query.
R7 replaces only the large cell/pin/snapshot dictionaries with arrays and
retains all actual binding, old-function/placement and route checks. These
host-script timings are **not** processor IPC or an FPGA performance gain.
Sealed successful query: `ventium-debugscan-query-cost-r3.bMwm08/closed-query.sha256`.

**R7 construction passes native0/input-pins0** and an independent closed-output
consumer. Guard collection finishes44.6s after entry, compared with378.1s in
R6; all connections finish56.9s after entry. The actual native graph checks181
new LUTs and889 input bindings, exactly32 debug-data D reconnects, unchanged
297,336 original primitives (reference/placement/old LUT function), and390
preserved original source groups. The3,794 affected original LUT input pins
are locked without moving any original cell. Output:
`ventium-debugscan-eco-build-r7.wfwxcG/native-output/scan_added_unplaced.dcp`,
SHA-256 `a4263464dd7e22d5cb031aae6463b027ae2e58dbede2ad653cfe3142617587e2`.
This is explicitly **unplaced/unrouted, not a bitstream or hardware repair**.
The first placement-only attempt fails before placing any cell: the native
help's `IS_OCCUPIED` example is not supported on this device's BEL objects.
That failed receipt is retained. R2 instead verifies vacancy through actual
BEL-to-cell relationships, empty SLICEL-site properties and the original cell
location inventory. **R2 placement passes native0/input-pins0:** all181 new
LUTs occupy separate empty sites, with889 verified physical input mappings.
All297,336 original primitive functions/placements and390 source routes remain
unchanged. Output:
`ventium-debugscan-place-r2.Y1ePCR/native-output/scan_added_placed_unrouted.dcp`,
SHA-256 `56eaac75640413090d9830b0c0434d496a024f6d2da6ece5f73972a6ddc14627`.
This is **placed but unrouted**, not a deployable bitstream. A separate bounded
affected-net routing script checks preserved original branch resources and
untouched routes. Its closed-placement consumer passes. Initial native
attempts reject `-eco -nets` and `-preserve -nets` combinations **before any
routing**; both retain native1/input-pins0 and separate sealed receipts.
A bare no-project check closes0 but is inconclusive: every command requires
an open project. A disposable two-cell design then proves
`route_design -no_psir -nets` actually routes its selected net, while confirming
both incompatible combinations. That toy pass is not a processor gate.

R3 uses the accepted command with one thread, an8GiB/no-swap cgroup and a540s
outer deadline. Before routing it verifies415,680 unchanged physical roots,
reusing the pinned1,459,317,012-byte baseline instead of creating another copy.
The router runs52s but **fails native1/input-pins0**:21 unrouted nets and five
node overlaps. Five specific fixed address-net branches conflict with debug
read-data FF D inputs. Most reported blockages are override-output routes to
those debug FFs; one tapped core FF, `pipe_mem_u_q_reg[mem_disp][15]`, also
cannot reach the new observer LUT within the router's local search. The
post-failure DRC's zero errors does **not** override the failed route verdict.
No output checkpoint, bitstream or board deployment is produced. Preserve
`ventium-debugscan-route-r3.ZIbEj4/closed-routing.sha256`
(`f9cc971bedc05cffb5d94e60fffd09fa01bf2df3f316ea436ee1384f4a60da1e`).
Inspect the local physical wiring before another layout attempt; do not unlock
CPU routes or move CPU cells to manufacture observer routability.

A read-only footprint query closes native0/input-pins0. The blocked core tap
already reaches the `G6LUT/A2` input at `SLICE_X108Y209`; the adjacent G5 LUT
is vacant. Its existing G6 LUT is a conditional function, not a raw-bit buffer,
so that output cannot substitute for the observation. The proposed identity
buffer shares the already-routed A2 input instead. All32 management read-data
FF Q outputs have exactly one leaf consumer: the PS AXI response FIFO. There
are43 vacant LUT/FF pairs in slice halves containing a management FF with the
same clock, enable and active-low synchronous reset. Footprint receipt:
`ventium-debugscan-footprint.ECaRiY/closed-query.sha256`.

The revised adapter restores the32 legacy management FF D connections and
adds32 shadow response FFs, relocating only the new override LUTs beside them.
It retains the original response clock, enable, reset polarity and latency;
only the unused private scan selectors can change the returned word. The
identity buffer increases the observer to182 LUTs/890 input connections, with
the same338-bit catalogue. Offline checks pass43,520 bank cases,4,096 random
envelopes, two buffer truth cases and768 register-transition cases. These are
algebraic checks, not hardware qualification. Inputs and proof are under
`ventium-debugscan-shadow.99S7OI`.

The first native adapter attempt passes all32 control/polarity and exclusive
consumer preflights, then fails when a new wire would cross the protected
SoC hierarchy: native1/input-pins0, no output checkpoint or deployment.
Receipt: `ventium-debugscan-shadow-build.9p5jxq/closed-adaptation.sha256`
(`5cde42b748e390ff165400f4d97528c3976839ac4a70f330565a4e8e88a74db3`).
The follow-up reuses each existing hierarchy-crossing response wire and
changes only its source inside the management block. It does not clear
hierarchy protection or relocate original cells. R2 gets through all32
connection changes but placement rejects bit22: its vacant H6 LUT shares
inputs with an occupied H5 LUT. That failure is retained separately
(`ventium-debugscan-shadow-build-r2.AVq2Bq/closed-adaptation.sha256`,
`0242d074220a28558bf01827a685e50f508d6e0e09a258425597c3644a3f4a5b`).
The corrected inventory excludes occupied halves and finds42 complete pairs.
The same offline proof passes again under `ventium-debugscan-shadow-r3.mqjfbk`.

**R3 adapter placement passes native0/input-pins0**:297,336 original
primitive functions/placements unchanged,182 new LUTs,32 shadow FDREs,
890 verified logical/physical LUT input bindings, all32 legacy D connections
restored and exactly32 exclusive response-wire sources replaced. All32
shadow clock/enable/reset polarities match their legacy FFs, and all358
protected original source routes remain unchanged. The G5 buffer shares the
old G6 A2 input without changing that original LUT's mapping or function.
An independent closed-output consumer passes after correcting its own Tcl
carriage-return escape in an expected name; the failed consumer receipt is
retained and was not a native implementation failure. Placed **unrouted** DCP:
`ventium-debugscan-shadow-build-r3.UxQzHt/native-output/scan_shadow_placed_UNQUALIFIED.dcp`,
SHA-256 `be6049fa2e45c2d67fc286ad93240e1dee64d8d0bb53a66acabb70310dd1f8c7`.
Closed adaptation manifest:
`dc04067343c2c88649d917267f94d163f32634e513f35c42eb806c5ddf53462d`.
Routing qualification, a bitstream and board validation remain outstanding.

The shadow routing attempt checks415,645 unaffected physical roots against
the original baseline; all match. Its explicit exceptions are32 response
wires plus the common clock/enable/reset nets, whose original branch
resources are protected. It selects607 roots,361 protected source branches,
and removes only the32 obsolete response route trees before routing. Native
binding identifies the management FF clock as the core MMCM output, not a
separate assumed PS clock. The router remains near ten overlaps and hits its
540s deadline: native124/input-pins0, no output checkpoint or bitstream, scope
inactive and vendor process family gone. This is **not** route qualification.
Sealed attempt: `ventium-debugscan-shadow-route.fm39e5/closed-routing.sha256`,
`9f9635568da0b5175033b97ca4fa23b16501a4227763f7aba4b7fcd6c50873ea`.
Next inspect conflict details in a diagnostic copy rather than repeating
automatic routing or relaxing processor protections. The installed image
remains unchanged.

The bounded diagnostic copy closes native0/input-pins0, but is **not** route
qualification. Its full reports identify95 nets affected by invalid sites,
despite `report_route_status -return_nets -route_type CONFLICTS` returning an
empty list. DRC identifies two PDIL-1 errors: `SLICE_X20Y199/A6LUT` and
`SLICE_X24Y191/F6LUT` are logically vacant but already implement constant
route-throughs. Placing override bits20 and10 there conflicts with the old
physical configuration. Logical BEL-to-cell vacancy alone is insufficient;
future placement must also account for physical routing resources, and full
route/DRC reports remain mandatory.

Packing the local identity buffer beside its old G6 LUT also introduces one
physical-only VCC connection, reported at `INT_X73Y209/IMUX_W46`. The logical
observer plan has no explicit constant input, but that does **not** imply zero
physical constant-routing work after packing. Account for the new connection
explicitly without relaxing protections on original constant branches. The
diagnostic removes only32 obsolete response routes; all297,336 original
primitive functions/placements and361 protected source routes remain
unchanged. Diagnostic checkpoint (not deployable):
`ventium-debugscan-shadow-conflicts.AFIe4U/native-output/scan_shadow_debug_unrouted_DIAGNOSTIC.dcp`,
SHA-256 `5b78ace21230c9ef76b188a982cce03fdcfdf08b21e9276a0778d5046522d5df`.
Sealed diagnostic manifest:
`880bcfde6c96931254c47ffd986a487752e753cb6927f44a25a6a19645d0edab`.
No board programming, clock change or production Quake run follows this
diagnostic. A separate read-only native resource query is the next step.

That read-only query closes native0/input-pins0 in93.6s; an independent
closed-output consumer passes. Native `BEL.IS_USED` identifies exactly the
two route-through LUTs;40 of the42 logically vacant complete pairs remain
available. The output site pins' `IS_USED` flags are zero even for those two
route-throughs, so those flags cannot substitute for BEL configuration checks.
The query also inventories471 logical constant groups (228 POWER,243 GROUND)
sharing the two physical constant trees. `get_nets GLOBAL_LOGIC0/1` finds no
ordinary net object. Sealed query:
`ventium-debugscan-routeaware-query.2tDvQ7/closed-query.sha256`,
SHA-256 `0e70cc46a0d26adf6ff2340b6f68410b9ceb78a4b3e33231a59977a14ae01d25`.

R4 uses that physical inventory, repeats the unchanged offline bank/transition
proof, and checks both LUT halves plus both FF BELs before placement. Native
placement closes0/0 with the original297,336 primitive functions/placements
unchanged. The explicit, waiver-free PDIL-1 check reports zero violations;
an independent consumer checks the full report and excludes both conflicting
BELs. Output remains **placed, unrouted, not deployable**:
`ventium-debugscan-shadow-build-r4.7xf3Ok/native-output/scan_shadow_placed_UNQUALIFIED.dcp`,
SHA-256 `d0c77bc5b977bbcd4af9fd239712cd74a7e24fdf98ccc46b9dedb1dd86f9374f`.
Sealed placement manifest:
`b7f0f5825fdb388369f1ebbfc1ca65c0e3c7dd64d804ff79364af82bea8a3517`.
The next bounded route explicitly handles both physical constant trees,
preserves original branch resources and GND's exact route, checks all471
aliases, and saves a diagnostic checkpoint before routing. Twelve offline
guard tests pass, including rejection of removed old nodes/PIPs, changed GND,
inconsistent aliases and incomplete routes. These are guard tests, not DUT or
route-qualification results. No board image changes on these results alone.

That route attempt closes native124/input-pins0 at its540s deadline. Its
preflight verifies415,174 unaffected routes exactly, plus all471 original
constant aliases. Native protection covers106,722 GND nodes/103,141 PIPs and
70,881 VCC nodes/57,944 PIPs. The physical-constant route succeeds with zero
warnings/errors: GND remains exact, all old resources remain present, and VCC
gains exactly one node and one PIP. The separate607-net observer route still
oscillates around7–8 overlaps. It is **not qualified**; no bitstream or board
programming follows. The sole vendor scope closes inactive without OOM.
Sealed attempt:
`ventium-debugscan-shadow-route-r2.MSsmAL/closed-routing.sha256`,
SHA-256 `5d396e896a23b68060e7e2300fd4dea099284dabb12d8741d8354dea530e9c97`.
Its prepared diagnostic checkpoint is saved **before** either router pass:
`native-output/scan_shadow_route_prepared_UNQUALIFIED.dcp`, SHA-256
`d33b004e5678c027f04030be50899e16c7ef3e775fa962730558bbce1a3fbc98`.
Do not claim that saved checkpoint contains the later successful VCC extension.

Control-group follow-up: bit11's selected primary `EFF` at `SLICE_X14Y206`
has a secondary `HFF2` peer. They share the clock/reset half but not the CE
group. Same-half matching alone does not prove enable routability:
[AMD's UltraScale CLB guide](https://docs.amd.com/r/en-US/ug574-ultrascale-clb/Clock-Enables)
documents distinct primary/secondary CE groups. This is a **hypothesis** for
the remaining route blockage, not yet a confirmed cause. The read-only native
query captures all 32 new/peer control-pin mappings and the 64 FFs occupying
their 20 selected sites. Bit 11 uses `CKEN3`; its old `HFF2` peer uses `CKEN4`.
The clock/reset mappings match, and no old primary FF occupies that upper
half. The difference alone is therefore not evidence of a conflict.

That query closes native1/input-pins0 because its final `-to_load` report
requests an enable target absent from the existing route tree. Keep it as a
**partial query**, not a native pass. Sealed partial evidence:
`ventium-debugscan-controlgroups.HCFbdp/closed-partial-query.sha256`,
SHA-256 `bdd47e794419969644a972396bc62e0737cadd7eb0549faa76622ba1ab5bf6d3`.

The subsequent one-pin diagnostic closes native0/input-pins0. Routing only
the new bit 11 CE pin with PSIR disabled succeeds in 38 s with no warnings or
errors. Its native full enable-net report says ROUTED; the target
`INT_X10Y206/CTRL_W2` is present. All 247 old CE nodes/246 PIPs remain, with
exactly one new node/PIP. All 297,336 original primitive functions/placements
and the enable's logical sinks remain unchanged; waiver-free PDIL-1 is zero.
The enable-group difference does **not** explain the remaining routing stall.
The first independent consumer rejects a mistyped expected baseline hash;
the corrected consumer passes without changing the closed native evidence.
Sealed native diagnostic:
`ventium-debugscan-bit11-enable.P1jmVE/closed-enable.sha256`, SHA-256
`b3e44533e49351d63393fdc99658c41e6aeb1c50fb2e98a17c9bfc2385a938a6`.
Corrected closed-consumer manifest:
`41e853c1bfb4b0bf4a1a01c4fc96937a177a3c8b53edc0ae9e29146472c08ab6`.
Its saved `native-output/scan_one_enable_DIAGNOSTIC.dcp` has SHA-256
`21380ad3fb9b7c2ff03d710718b088423c0d049ad3dce4a99597c8d613debd36`.
It is **not** a complete routed or deployable design: only that enable branch
is qualified, not all unaffected routes or the observer. Next separate the 214
new observer/response nets from the original-source tap branches to localize
the remaining blockage. No synthesis, board programming, clock change or
production Quake run occurs on these diagnostic results.

Routing just the 214 new observer/response nets, without selecting any
protected original net, falls from 18 overlaps to one and stalls. A SIGINT to
the exact private Vivado PID cancels both `route_design` and its entire Tcl
source; the script's catch does not run. Native1/input-pins0 closes with **no
saved output checkpoint**. The router's cancellation-time DRC reports zero
errors, but that is not routing completion. Sealed attempt:
`ventium-debugscan-freshnets.pmb1NZ/closed-routing.sha256`, SHA-256
`4bc5e359edd0215c39b35e34efbdf684e7ee9ac1d847cfbfcbd4610cdb32a4d0`.
Save completed stages before a later router call; do not assume cancellation
will permit post-route checkpoint/report commands to execute.

The staged follow-up first routes the physical constants successfully, checks
all old constant nodes/PIPs, verifies GND's exact route, and verifies exactly
one new VCC node/PIP at `INT_X73Y209/IMUX_W46`. All 297,336 old primitive
functions/placements remain unchanged. It saves the completed constant stage
before trying the other 213 fresh nets, excluding `local_ff_buffer/O`.
That 213-net route also stalls at one overlap and is canceled; the exclusion
does not remove the blockage. Native1/input-pins0 closes; no 213-net result
is accepted. The earlier saved stage survives:
`ventium-debugscan-freshsplit.4KMxem/native-output/scan_constants_DIAGNOSTIC.dcp`,
SHA-256 `e1e49c6380f3f18e542506f28f87b1ca6b3f1c1bdb903f1db0d66e80c1d8e734`.
Sealed attempt: `ventium-debugscan-freshsplit.4KMxem/closed-routing.sha256`,
SHA-256 `46c4ffccfb50662930a9cb4d2750fb229d49aecdd7fb047762dca42ed82d262d`.
An independent consumer accepts only that preceding constant stage for
further diagnostics, explicitly not route or hardware acceptance. Next query
the actual used site routing resources and native router parameter inventory
without mutating this saved design. No further combined automatic pass or
processor-route relaxation is justified by these results.

The read-only resource query closes native0/input-pins0 in 57.6 s, enumerating
all 214 new outputs across 170 sites and their used site PIPs. It writes no
design checkpoint. Sealed query:
`ventium-debugscan-routeparams.6B5Xar/closed-query.sha256`, SHA-256
`18dd337fce7f71fe5d5cf137f724e2f2688d6cf3a5e4c18126698620ebd37b47`.
Separate native-help/report queries confirm 17 public parameters, none a
routing iteration limit; `report_param *route*` exposes no matching parameter.
Do not invent or set an undocumented iteration knob. Native help also
confirms that `-no_psir` disables **physical synthesis in the router**, not
site-internal routing. Keep it enabled; no processor synthesis optimization
is authorized as part of this observer-routing diagnostic.

The response-only follow-up closes native0/input-pins0. All 32 replacement
debug-response wires route in 32 s with zero final overlaps and no
warnings/errors. All 297,336 original primitive functions/placements, all 32
shadow-FF configurations and exclusive response sinks remain unchanged;
waiver-free PDIL-1 is zero. An independent consumer accepts only this
completed diagnostic stage, not the full design. Sealed attempt:
`ventium-debugscan-responses.zglMyD/closed-routing.sha256`, SHA-256
`16d2864f05e7a6b215e868f3814acfaedc7af6d6d66d3f3ca0c5ed86b8755e07`.
Saved `native-output/scan_responses_DIAGNOSTIC.dcp` has SHA-256
`97b4a41b5289c71ff4c3f8fc7fff53127c04f7fd766821852ba0d797381a323b`.
The next staged pass preserves those completed response routes and separates
32 final word muxes, three shared controls and 114 lower-level LUT nets,
saving each completed stage before proceeding. The observer remains
**unqualified and undeployed**; the production timedemo has not been restarted.

The first word-mux group still stalls at one overlap; that canceled attempt
does not produce a completed stage. Sealed attempt:
`ventium-debugscan-lutnetwork.1e21hj/closed-routing.sha256`, SHA-256
`5e13b34e18709d8a71fa985ee7a8b628e7917d361ae404620299125a9c66110f`.
An individual-pin pass then routes bits 0–6 successfully and naturally fails
at bit 7. Native reports a potential placement issue on
`word16_7/O` (`SLICE_X101Y188/A6LUT`) → `rdata_override_7/I1`
(`SLICE_X21Y196/B6LUT`, physical input `B2`, node `INT_X14Y196/IMUX_E9`).
Its failure-time zero-error DRC is not a routing pass. The native failure
closes input-pins0 and executes the final input-preservation checks. Sealed
attempt: `ventium-debugscan-wordpins.UsTX0t/closed-routing.sha256`, SHA-256
`0075571b02648491d9ad4b195d8a11c3784ee5e9b991cbafd6d970bb7ee8ed7e`.
Only the preceding checkpoint through bit 3 was saved; it does **not** contain
the later successful bits 4–6:
`native-output/scan_word_through_03_DIAGNOSTIC.dcp`, SHA-256
`d25ea021ca3e3006cae6a2a8e39d3a3929b4e0110f19aa7629ad15727a00593a`.

A read-only endpoint inventory closes native0/input-pins0 and its independent
consumer passes. Sealed query:
`ventium-debugscan-word7-resources.KKgpxY/closed-query.sha256`, SHA-256
`45f54a25bde816baa6d549f20ad5b6257beedaa5f17f98794aa180046d161df5`.
The source slice contains only the new word-7 LUT, has no used site PIPs,
and has a physically unused/unreserved/non-prohibited B6 LUT. This is a safe
observer-only placement candidate, **not** proof that its interconnect exits
are free. The initial site-pin neighbor query returns the endpoint nodes
themselves; it is not accepted as a routing-resource ownership proof.
Actual neighboring interconnect nodes are queried from those node objects
in the subsequent one-LUT diagnostic. Do not confuse logical vacancy, BEL
vacancy, and end-to-end routing feasibility.

Moving only new `word16_7` from A6 to B6 in the same source slice fixes its
single-pin route in 38 s (native0, ROUTED). The LUT INIT, locked logical pin
mapping and target remain identical. All 297,336 original primitive functions
and placements, all 214 observer configurations except that one BEL, the 32
completed response routes, and word routes 0–3 remain unchanged. The completed
stage is saved before the next router call:
`ventium-debugscan-word7-onefix.wEMoyB/native-output/scan_word7_source_B6_DIAGNOSTIC.dcp`,
SHA-256 `b68ed36bb156a6632c8554417ddebd7f185f35fd12aa04cb3819f45200f6147f`.

The remaining 27-word batch then naturally fails at another placement-blocked
connection: `word16_16/O` (`SLICE_X114Y197/A6LUT`) →
`rdata_override_16/I1` (`SLICE_X25Y189/B2`). The whole attempt closes
native1/input-pins0, not a 32-word pass. Its independent consumer accepts only
the earlier saved five-word stage (0–3 and 7) for further diagnostics. Sealed
attempt: `ventium-debugscan-word7-onefix.wEMoyB/closed-routing.sha256`,
SHA-256 `99a22150a8973b71ecaa5d6a41807bcfd881cf4ca796c205bacbd7cb84336538`.
The same guarded source A6→B6 relocation does **not** fix bit 16. That attempt
closes native1/input-pins0 without an output checkpoint and is discarded:
`ventium-debugscan-word16-onefix.qsAmmK/closed-routing.sha256`, SHA-256
`4e2c52558b13ee6947e7d10a7c5cd7b4b6ce5d12b276c715545df6bc282f5abc`.
Subsequent attempts return to the saved bit-7 checkpoint, keeping source16
at its original A6 placement.

The first target-pin remapping attempt is rejected by Vivado before routing:
changing `LOCK_PINS` on an already-placed, locked LUT requires unplacing it,
clearing the old lock, setting the new lock and replacing it. This is a
native API failure, not a routing pass. Its closed rejected manifest is
`ventium-debugscan-word16-pinfix.p9rf2C/closed-rejected-pin-update.sha256`, SHA-256
`1ee43483a77bf24d0924093b92e7a33b19ec4269765100641f98cddb83c44223`.

The corrected attempt unplaces **only** the new `rdata_override_16` observer
LUT, remaps logical I1 from physical A2 to A5, then replaces the LUT at the
same `SLICE_X25Y189/B6LUT`. Its logical INIT `16'h0ACA`, connectivity and
all other pin mappings remain unchanged. B5 shared-input resource vacancy is
checked first. The new endpoint is site pin B5 / node
`INT_X17Y189/IMUX_W27`; the old B2 endpoint used `IMUX_W9`. No processor cell
is unplaced, moved or unlocked. Bit16 now routes successfully, followed by
all remaining26 word connections.

This attempt closes native0/input-pins0 with all32 word connections routed,
PDIL-1 violations0, all297,336 original primitive functions/placements
unchanged, all32 response routes unchanged, and all214 observer configurations
unchanged except the explicitly checked I1 pin map. The independent consumer
prints `PASS_OBSERVER_WORDS_ONLY_NO_FULL_ROUTE_OR_HARDWARE_ACCEPTANCE`.
Saved checkpoint:
`ventium-debugscan-word16-pinfix-r2.vAieNW/native-output/scan_all_words_DIAGNOSTIC.dcp`,
SHA-256 `490de3a4a405274f5a67a230ae9d45fb99ece6f42598e3ef128dc5fc7d7e20e8`.
Sealed attempt: `ventium-debugscan-word16-pinfix-r2.vAieNW/closed-routing.sha256`,
SHA-256 `a00d1eea4622acea7211429c8a2e62d09763e2fc4137cecc91e4ef55b3d4d32b`.

These changes address **observer routing, not the silicon CMP/branch defect**.
The next stage protects all64 completed response/word routes and successfully
routes the three new control outputs and114 lower mux outputs, saving each
stage before the next router call. It closes native0/input-pins0; the independent
consumer prints `PASS_CONTROL_LOWER_STAGES_ONLY_NO_FULL_ROUTE_OR_HARDWARE_ACCEPTANCE`.
All297,336 original primitive functions/placements, all214 observer
configurations and all64 completed routes remain unchanged; PDIL-1 is0.
Saved lower-stage checkpoint:
`ventium-debugscan-lowerstage.9UEvMx/native-output/scan_lower_DIAGNOSTIC.dcp`,
SHA-256 `ce2753305b3f7e60d73f6ea3707e67d045b9e8e8bfe3c4215836f363295828f5`.
Sealed attempt: `ventium-debugscan-lowerstage.9UEvMx/closed-routing.sha256`,
SHA-256 `8d03f3f4c54ea4a6fd6c5f1f72ad510d6bbccd75ac9b3c350efc9581c09c243c`.

The complete native route report is still incomplete:34 unrouted nets and356
nets with unrouted pins, including the new address/control/tap inputs. A
staged mux-output pass is **not** a full routing pass. The next guarded attempt
protects all213 completed observer outputs (including32 local intrasite
outputs), the inherited physical constant trees, original source branches and
all unaffected original routes. It routes only pending original-source taps
and the new local buffer output, then requires full native route booleans,
full DRC and the complete original-route/resource/logical guards. No
full-route, timing, hardware or gameplay acceptance is yet claimed, and no new
image has been deployed.

The net-wide tap attempt verifies all415,174 unaffected original routes before
routing, protects the213 completed observer outputs, and saves its prepared
checkpoint. Routing390 pending source nets then stalls at seven overlaps;
the exact private Vivado process is interrupted, not left running. It closes
native1/input-pins0. Its pre-router checkpoint is diagnostic only, and there
is no accepted post-router result. Sealed attempt:
`ventium-debugscan-tapstage.VyT7YY/closed-routing.sha256`, SHA-256
`84b2775097fca0705b8c89aae68cb6509f07fcbb02ef657dceca62f23a7016e2`.

Pin-directed routing of741 observer/restored-debug inputs avoids that endless
net-wide overlap loop and identifies eight blocked loads across seven nets:

| Original source | New observer load |
| --- | --- |
| `dbg_arch_sel_reg[4]/Q` | `rdata_override_10/I3`, `rdata_override_18/I3` |
| `u_dbg/s_rdata[24]_i_1/O` | `rdata_override_24/I0` |
| `u_mgmt/s_rdata[28]_i_1/O` | `rdata_override_28/I0` |
| `u_mgmt/s_rdata[30]_i_1/O` | `rdata_override_30/I0` |
| `u_dbg/s_rdata[5]_i_1/O` | `rdata_override_5/I0` |
| `u_dbg/s_rdata[7]_i_1/O` | `rdata_override_7/I0` |
| Core retained U `is_nop/Q` | `word4_29_0/I1` |

The native full-route report now has five unrouted nets and two nets with
missing pins:225,195 of225,202 routable nets are complete. The router still
returns failure. Its saved checkpoint is **unqualified**, SHA-256
`5c6b63e245107d1099dc8241017e8e25783fd3540803b27cb25388b501c87995`.
Original primitive/function/placement, protected-source resource, completed
observer-route and constant-tree checks finish, but the550-second construction
deadline expires during the full original-route comparison. The independent
partial/full consumers must reject missing final preservation checks; do not
reuse this failure as a qualified routing pass. Sealed attempt:
`ventium-debugscan-tappins.O4Vwqw/closed-routing.sha256`, SHA-256
`7ec1508c5e80b7f4b188b25b4eae28ab575a0ce4a8d495e24f99413832555a27`.

All eight affected targets are new LUT4s, with two unused logical inputs in
their six-LUT placements. The next test returns to the sealed lower-stage
checkpoint rather than adopting the incompletely audited failure. It first
checks the paired fifth-input BEL's physical vacancy, then remaps only the
blocked logical input to A5 at the same LOC/BEL. Logical INIT, connectivity
and original cells/routes must not change. Nine incident **new observer**
routes may need temporary constraint removal during same-BEL replacement;
their full constraints and all213 completed output routes must be restored
exactly before tap routing continues. No original processor route is unlocked.
This is an observer repair candidate, not a processor fix or hardware pass.

The guarded eight-target remap completes its placement/configuration checks
and restores all213 completed observer outputs exactly. Seven blocked loads
now route; the retained U `is_nop/Q` load still fails at the new A5 endpoint.
The full native report has225,201 of225,202 routable nets complete, one net
with an unrouted pin and no wholly unrouted nets. The remaining connection is
`pipe_mem_u_q_reg[is_nop]/Q` at `SLICE_X106Y203/EQ` to
`word4_29_0/I1` at `SLICE_X115Y196/A5`
(`INT_X77Y196/IMUX_E26`). Its earlier A2 endpoint also failed; this does not
establish whether the source exit or destination entry is responsible.

Unlike the preceding deadline-expired attempt, this attempt completes the
entire preservation audit: all297,336 original primitive functions/placements
and415,174 unaffected original routes match, all607 source/sink groups match,
361 protected source branches retain their resources, both inherited constant
trees match, all890 new input bindings are verified, and all213 completed
observer output routes match. The only observer configuration differences are
the eight explicitly audited logical-input-to-physical-pin remaps; INIT,
connectivity and LOC/BEL do not change. Native closes1/input-pins0. The
independent consumer prints
`PASS_PRESERVED_PARTIAL_DIAGNOSTIC_ONLY_NO_FULL_ROUTE_OR_HARDWARE_ACCEPTANCE`.

This checkpoint is suitable only as the preserved base for the final tap
diagnostic, **not** for bitstream generation or deployment:
`ventium-debugscan-tappins-map8.3dDG0v/native-output/scan_taps_routed_UNQUALIFIED.dcp`,
SHA-256 `f426d3376aa1efc29c7d0498509f2f57acafbd933516162bc75ada3da46e4a84`.
Sealed attempt:
`ventium-debugscan-tappins-map8.3dDG0v/closed-routing.sha256`, SHA-256
`f8fcb832a5aac92b065d292620a1e76e3f887ae9b80a92c542544d7a57237130`.
Next inspect the original NOP source's actual routed receivers/exit and the
remaining target's physical entry resources before selecting a repair. A
duplicate FF with matching D/C/CE/R would not prove observation of the original
retained state and is not an acceptable replacement for that tap.

The first NOP endpoint inventory stops at an invalid net-name equality
assumption, before placement or routing; it closes native1/input-pins0.
Rejected query manifest:
`ventium-debugscan-nop-resources.7PTW3x/closed-rejected-query.sha256`, SHA-256
`7b170b093e75253f6b0891a490456ae8849de5487931e45c64c9ef4aca8f308b`.
The corrected read-only query exposes different hierarchical alias names for
the same physical connection. The target's unique driver is the actual
original U `is_nop/Q`; both aliases report identical ROUTE, FIXED_ROUTE, eight
physical nodes and seven PIPs. Alias names alone are not electrical identity.
Native closes0/input-pins0, and the separate alias-aware consumer passes.
Sealed query:
`ventium-debugscan-nop-resources-r2.ZNDDwj/closed-query.sha256`, SHA-256
`9fb3279e69876e037d835773597dbff2622349808a770927807a3a98d8c7b7b1`.
The initially pinned name-equality consumer is retained unchanged, not silently
edited into a pass. This query failure is not a processor defect.

The source has three original local receivers. Original LUT5
`u_icache/gpr[6][0]_i_31` occupies `SLICE_X106Y203/G6LUT`, with logical INIT
`32'h0000202A` and I0..I4 physically on A1,A5,A3,A4,A2. Its paired G5 BEL is
physically unused/unreserved/non-prohibited, and A5 already carries the true
NOP FF value. The proposed repair adds one identity LUT1 at G5, sharing that
input, and moves **only** the new observer load behind its output. It does not
duplicate a processor register or alter the reader's338-bit catalogue.

The offline proof checks all64 paired-LUT input assignments (32 original O6
cases with A6 high),43,520 scan-bank cases and4,096 random envelopes. The
compatible physical table is `64'h00022022ffff0000`: its low32 bits implement
O5=NOP and its high32 preserve the original O6 function. This requires the
physical G6 A6 input to be tied high; a native placement pass alone does not
discharge that condition. The bounded native ECO must verify the exact physical
VCC extension, original G6 logical INIT and all five physical input
mappings, unchanged original NOP route, all214 existing observer outputs,
the complete original-route audit, full native routing and full DRC before
bitstream generation. Offline proof only:
`ventium-debugscan-nop-buffer.McEzrg/checks/result.json`; native plan SHA-256
`39657e2a6ca9a2b4d3ad796e4faeed3b2d4c0479db258df24a8c71f994a71d6c`.
No image is deployed or hardware acceptance claimed at this point.

The first native NOP-helper attempt passes the exact shared-input/BEL checks
and inserts only that LUT and observer-input splice. The physical-constant
router returns0 with zero overlaps, but the required power-tree footprint
check rejects its result. The inherited GND route and both inherited constant
resource subsets are preserved through that check; this is **not** proof that
the new A6 tie exists. No two-pin signal route, full preservation audit,
accepted checkpoint, bitstream or deployment follows. It closes
native1/input-pins0. Rejected attempt:
`ventium-debugscan-nop-buffer.McEzrg/closed-rejected-constant-footprint.sha256`,
SHA-256 `2cb02b30efa43b42a1a1ded781161b900263f51d3807896174aeb197779fe548`.
The next diagnostic retains the same acceptance condition but saves an
unqualified post-physical-router checkpoint and reports the actual added
nodes/PIPs before rejecting a mismatch. Do not replace the required physical
tie proof with the router's successful exit or the earlier offline truth table.

The saved diagnostic resolves the footprint mismatch: GND is unchanged, and
POWER gains exactly `INT_X71Y203/VCC_WIRE` plus `INT_X71Y203/IMUX_E46`, with
the single PIP `INT_X71Y203/INT.VCC_WIRE->>IMUX_E46`. The required A6 node and
PIP are both present; all inherited resources remain. The correct new power
footprint is70,884 nodes/57,946 PIPs, not70,883/57,946. The earlier TAP76 tie
needed only one additional node because its tile's VCC driver node was already
represented; this tie also needs its local driver node. This is a guard-count
assumption error, not an unexplained processor/resource change.

The diagnostic closes native1/input-pins0, with no full route/hardware pass.
Its independent consumer accepts **only** the exact constant delta and sealed
diagnostic evidence. Checkpoint:
`ventium-debugscan-nop-buffer-r2.XTXcgs/native-output/scan_nop_physical_DIAGNOSTIC.dcp`,
SHA-256 `658970a80f44ed122055c39338117f30f608a3df36b31dc362a0606a442d8343`.
Rejected attempt manifest:
`ventium-debugscan-nop-buffer-r2.XTXcgs/closed-rejected-constant-footprint.sha256`,
SHA-256 `3f0cf0ed76ac7094759301f6f20a4fd43fc6139c2fd234eec0bb705665f1968b`.
The next full guarded attempt returns to the preserved pre-buffer checkpoint
and requires exactly those two added nodes and one added PIP, with no other
constant changes, before routing the two signal inputs and auditing the result.

The corrected full attempt closes **native0/input-pins0**. Both signal pins
route successfully; all225,203 routable nets are fully routed, with zero route
errors. Native `ROUTED_FULLY=1`, `ERRORS_IN_ROUTES=0`; full DRC has zero errors
and zero critical warnings. The lone router warning is the expected empty
`PDIL-1*` violation query, not a waived violation.

The full preservation audit passes:297,336 original primitive configurations/
placements and415,174 unaffected original routes match;361 protected source
branches retain all resources;471 constant aliases are verified against the
original immutable tree data;214 existing observer output routes match.
All608 source/sink groups match the explicitly spliced graph (the NOP source
exchanges only the unrouted observer load for the helper input), and891 new
input bindings are checked. The NOP source's original eight-node/seven-PIP
route is identical, all five original G6 input mappings and its logical INIT
remain identical, and the exact two-node/one-PIP power extension is verified
before and after signal routing. The observer totals183 LUTs/32 shadow FFs;
no processor FF is duplicated and no original route is unlocked.

The independent consumer prints
`PASS_PRIVATE_NOP_BUFFER_FULL_ROUTE_NO_STA_OR_HARDWARE_ACCEPTANCE`.
Full-route-verified checkpoint (the cautious filename remains unchanged):
`ventium-debugscan-nop-buffer-r3.V8pODG/native-output/scan_nop_buffer_routed_UNQUALIFIED.dcp`,
SHA-256 `ab46d01b9ab8562f35b3e2e1ac418bcd0970f2ed765fb568928a052c8347de78`.
Sealed attempt:
`ventium-debugscan-nop-buffer-r3.V8pODG/closed-routing.sha256`, SHA-256
`cf5ece336be88bf4ef31c4e3b56b902a0855d821db41858939b567ebf662b86f`.
This discharges the **observer's physical routing** gate, not timing, hardware,
the CMP/branch defect, gameplay IPC or timedemo acceptance. Generate only the
native raw BIN from this closed checkpoint; do not synthesize/reimplement the
processor, run bootgen or byte-swap the BIN. Board testing must still reproduce
the original failing case and the passing controls before packet attribution.

Native bitstream generation from that closed checkpoint also closes
**native0/input-pins0**. Opening it again confirms full routing, zero route
errors, zero full-DRC errors/critical warnings and the unchanged25 ns core
clock (40 MHz;100 MHz reference). No synthesis, placement, routing or clock
change is performed. `write_bitstream -bin_file` completes with zero warnings,
critical warnings or errors. The raw BIN is20,606,636 bytes, with native sync
`aa995566` at offset80; its `.bit.bin` copy is byte-identical, without bootgen
or byte swapping.

Native output:
`ventium-debugscan-bitgen.0Neit8/native-output/ventium_fpga40_debugscan.bit.bin`,
SHA-256 `3be5b6e464f27f1125540e3cb60c61dc0e45c8e5ce3f567a9802f40bc54ff14d`.
Sealed generation:
`ventium-debugscan-bitgen.0Neit8/closed-bitgen.sha256`, SHA-256
`75aa0cf36584d41a2a22d1e235d5822d8961ef4acc72923756e8ab4ff2248727`.
The independent consumer prints
`PASS_PRIVATE_NATIVE_RAW_BIN_ONLY_NO_STA_OR_HARDWARE_ACCEPTANCE`.
The original raw BIN is retained unchanged for rollback (SHA-256
`30b0178eb924eb2914bda6300f7ef3f3bef233b48d821ef77bf452349f8beefb`).
This is a bitgen/provenance pass, not a timing sign-off, silicon-clock
measurement, functional repair, gameplay measurement or completed timedemo.

The sealed native BIN is deployed on October6 with the original image retained
for rollback. Source and `/lib/firmware` hashes both match the generated BIN;
the manager independently reports `operating` and IDENT is `a0486501`.
The five-second read-only clock admission measures200,004,225 cycles over
5.000120971 seconds: **39.999877 MHz**, with zero retirements. `CTRL=1` and
`FRZINFO.frozen=0` remain true through100 guard checks and before/after the
sample. Production pins and uploaded files still match. Deployment closes0,
and the separate host consumer verifies all sealed deployment artifacts.
Evidence: `ventium-debugscan-deploy.BL9amZ/native-export/closed-deployment.sha256`,
SHA-256 `d19deb2b0424bd2e93ca7c1a5594a8b92281024608fdbf6c673872a585e03870`.
This proves image transport/manager identity and the held-reset core clock,
not CPU correctness or a successful Quake timedemo.

Board scratch cleanup removes only the closed `rC7oCB` run and its duplicate
board export, after checking native closure, all37 sealed files and the kept
VHD seed. It frees53,465,088 bytes. Full evidence remains in the host's
`ventium-private-jp-bad-boundary.oE0Zzd/exception-log-rC7oCB-export`; its omitted
private VHD is identical to the retained board seed. Production media and the
latest closed control remain untouched.

The private reader at `ventium-private-scan-reader.tLwjM1/read_scan.py`
requires an already-quiescent, **non-frozen** core, the original execution-debug
capability, and the new bank signature/metadata. It writes only the selector
CSR and restores the previous selector on success or failure. Two complete
scan reads and before/after architectural scans must agree. It rejects an old
image before interpreting packet words, checks all unused bits/selectors,
and reports missing optimized packet fields as unknown. A retained owner EIP
other than `14562` is explicitly not attributable to the failing CMP.
Eight fake-MMIO tests pass, including338 one-hot physical-bit checks, four
no-write precondition rejections and nine post-write safety/coherence failure
cases. These are **offline tests only**. The separate October6 board capture
now demonstrates coherent reset/bad-boundary reads and reproduces the defect;
it does not extend those eight fake-MMIO results into a full hardware or ISA
qualification.

Attribution caution: matching retained owner PC is necessary, **not sufficient**
to identify a dynamic instruction. In the frozen core, the packet FFs update
only when a new memory request must wait; immediate acknowledgements can use
the live decode without updating them (`core.sv:7473` and the effective-packet
mux at6155). Repeated executions of the same PC can also leave an older owner
with the same value. The ACTIVE copies report retained selection at capture,
not a history of which packet retired. Correlate the halt, retire evidence and
memory-transaction ownership before attributing a packet to the failing CMP;
do not turn an owner-PC match into a causal or timedemo acceptance claim.

## Live-input inventory and next diagnostic

The first read-only query finds only one of88 requested exact RTL net names.
That is not evidence that the missing signals are zero or absent: native
synthesis has renamed/merged their logical aliases. A second query follows
actual original primitive pins instead. Its initial attempt rejects on the
first flags-register D input because a valid `INTRASITE` connection has no
intersite nodes/PIPs; calling `get_property` on that empty object list is a
query-script error. Native exit1/input-pins0 and the unchanged parent DCP are
sealed in `ventium-debugscan-live-pins.qLSKml/closed-rejected-query.sha256`
(SHA-256 `47c9a894a73a3a1293cb342efd9aa2c6f79cd37f958d79f33698b7276b1a2f60`).

The corrected, separately pinned query closes native0/input-pins0 and its
independent consumer passes. It records251 matched primitives,1,137 pins and
14,604 net names; broad name categories include replicas/carry cells and are
**not** counts of distinct architectural registers. It finds the original
retire-valid FF, EIP/primary-PC pins, both retained-packet length inputs,
V-condition/displacement inputs, flags PF input and seven state bits. The
primary-PC FFs have no functional reset on their R pin, whereas retire-valid
does; do not copy a guessed generic reset. The absent `retire_pipe_valid` name
must not be used as a capture enable. Parent CPU logic, routes and board state
are unchanged by these inventories. Sealed query:
`ventium-debugscan-live-pins-r2.gJvNcj/closed-query.sha256`, SHA-256
`727769977cdf45b925a72138efa6921f14177d6d498967c808881fb432861925`.

The proposed general diagnostic samples original pre-edge inputs every clock,
then uses the **original registered retirement pulse** on the following clock
to retain those inputs together with actual original PC/EIP/PF outputs. This
aligns delayed memory, immediate memory and consecutive retirements without
mistaking a newly decoded next instruction for the retiring packet. It is new
diagnostic state, **not a duplicate FF claimed to prove an original FF's value**.
Length bit3 remains unobserved; raw live decoder inputs are not selected
effective-packet evidence when ACTIVE is set. No EIP-specific hardware filter,
pairing disable, CPU fix or additional observer deployment has been made.
Primitive simulation, scan truth-table/coherence checks and full physical
preservation/routing gates must precede any deployment of this extension.

### Two-edge sampler: offline proof and rejected physical attempts

The logical sampler now has84 pre-edge FFs and150 retirement-record FFs.
Its retained record includes actual original primary-PC/EIP/PF outputs plus
the preceding edge's raw EIP input, live length/condition/displacement inputs,
ACTIVE, EIP enable, PF input and seven state bits. Capture uses the original
registered retirement pulse through an identity-LUT enable buffer. Selectors
109–115 expose signature/metadata and150 bits; the original338-bit bank is
unchanged. This is general diagnostic state with no instruction-PC filter,
CPU RTL change or additional MMIO response cycle.

Installed Xilinx FDRE/LUT1 functional models pass8,168 checks, including all
eight-clock retirement patterns, consecutive retirements, per-bit propagation,
disabled-original-EIP-enable D/Q discrimination, halted retention and reset
priority. Independent scan checks pass31,424 cases. Existing64 model traces
contain4,096 committed CMP/JP windows:684 immediate and3,412 retained-memory
windows have the expected next-edge original PC/EIP/PF alignment. This replay
does **not** claim64 complete seed gates or hardware timing qualification.
Logical catalogue SHA-256:
`e5439cc145fc7f62c6b60e9300fc96560c0a6d2e0115d908bf5a419157696394`.
Offline closure: `ventium-debugscan-retire-plan.dlobDM/closed-offline-tests.sha256`,
SHA-256 `caab0b7771beddb9f313b7c1f01f50d2e8a9f99b931474f5a3079a490ae2af96`.

The dual-bank reader also passes10 fake-MMIO tests, with150 new and338 old
one-hot bit checks. It requires an already-halted, non-frozen core; writes
only the selector CSR; restores that selector on failure; checks signatures,
padding, unused selectors and two complete coherent reads; and compares a
valid record's actual PC/EIP/PF against independent original debug values.
An old retained-only image is rejected before payload interpretation. Its
seal is `ventium-private-retire-reader.vEoE1U/closed-reader-tests.sha256`,
SHA-256 `0148f0cf1a3d4dc62cc973c72b5794b493bd964e88ee700468fe4cb7ebd7c170`.
These remain offline protocol tests, not a deployed extension or CPU pass.

The first native preflight rejects a guessed reset inversion **before any
construction**. The original retire-valid R pin is non-inverted0 despite its
driver's misleading `core_reset_n` name. A matching reset0 vendor-model test
passes8,168 checks; its closure SHA-256 is
`813c1672e0f432e50f0db087bbb653200d7f8c47b81dc7a072acb7ace6a05665`.
Rejected preflight seal: `ventium-debugscan-retire-eco.nz8GFx/closed-rejected-preflight.sha256`,
SHA-256 `6a2f4790d73e0314797ff450b2c6b12239bc538fd899bc1b9b7e9f9be5f054ec`.

The reset0 physical attempt then packs16 independent diagnostic FF inputs per
fresh slice. Native routing reports overlapping/unreachable connections,
including record FF2 paths and the changed debug-response inputs. It reaches
the580-second bound: **native124/input-pins0**, not a routing pass. Its prepared
checkpoint must **not** be bitgenerated or deployed. The unchanged parent DCP
and board image remain available. Rejected routing seal:
`ventium-debugscan-retire-eco-r2.strCm2/closed-rejected-routing.sha256`, SHA-256
`e84631cff0bef67b28aac6a65f61fad7bf00b7a41e97dd1128b0aee78e223b70`.

The revised physical plan uses only eight FF1 lanes per fresh slice, each with
a matching identity6LUT data path:234 FFs and339 LUTs,573 new primitives total.
The logical catalogue/scan ABI is unchanged. Its vendor-model test again
passes8,168 checks;468 identity-buffer truth cases and31,424 independent scan
cases pass. Closure: `ventium-debugscan-retire-eco-r3.Co7axy/closed-buffer-tests.sha256`,
SHA-256 `1b4c81cc56e3cd5b9fd8fba7e7e271a368f06a0d0b25c3fb64caca306dcb24db`.
Only the completed **pre-construction baseline data** from the rejected
attempt is reused, with its seal, unchanged parent identity and all416,253
original net groups checked; the failed ECO is never treated as accepted.
The revised attempt closes **native1/input-pins0** on its550-second Tcl budget,
before construction: only original-pin/constraint inventory records exist,
with no new checkpoint. Its seal is
`ventium-debugscan-retire-eco-r3.Co7axy/closed-rejected-inventory.sha256`, SHA-256
`b402f3593ec15e15f76416596a41ac6252e903fb0eb80acd30c1ab3eb62ca448`.
The stack reports the budget check inside cached route loading; this attempt
has insufficient stage instrumentation to attribute all preceding time to one
query. A separate data-only check indexes all416,253 recorded names
in1.025 seconds and parses all415,782 nonconstant routes in2.270 seconds total.
The next attempt keeps the tested physical plan unchanged, resolves its
complete recorded name set against all native hierarchical nets, and adds
stage timestamps. No additional observer image has been deployed.

That next attempt matches all416,253 recorded names against587,412 native
hierarchical nets (native query20 ms, name matching5.571 seconds). It then
closes **native1/input-pins0** at the same550-second budget, still inside the
cached-route loader and before construction. This separates the successful
name lookup from the unresolved loader delay; it is not full route closure.
Seal: `ventium-debugscan-retire-eco-r4.dKUXqw/closed-rejected-cache-loading.sha256`,
SHA-256 `dcd1907af7dbc50506ad46ca9c3d268097d8bf2145d104bb1684989751e6305f`.

The array-lookup revision reaches the first constant alias promptly, but
rejects `get_property TYPE` because its value is an ordinary net-name string,
not an accepted native DB object. This is a **diagnostic-script object-cache
defect**, not an FPGA constant-tree or processor failure. It closes
**native1/input-pins0** before construction; no new checkpoint is written.
Seal: `ventium-debugscan-retire-eco-r5.1hMfQI/closed-rejected-object-handles.sha256`,
SHA-256 `aa73914ce2c88b7d9d5697433d11af57bf5d09a84805643cf3bc403e97315ae2`.
The subsequent revision retains native objects directly in the shared array,
with no ordinary dict/list return conversion. It now loads the complete
baseline and passes preservation preflight:297,551 parent primitives,
416,253 inherited groups,191 source bindings,3,990 original mapped LUT inputs,
1,930 constraint-only locks and471 constant aliases. Both constant trees
match the cached parent and already have matching inherited route locks.
This confirms the loader/cache repair, **not** final routed preservation.

Construction places234 sampler FFs and234 matching data buffers, then rejects
a heuristic that tries to get a slice coordinate for the VALID-bit constant.
Those matched buffers are already placed with their FFs; they need no source
coordinate. The attempt closes **native1/input-pins0**, with no checkpoint
written and no routing/bitgen/deployment. Seal:
`ventium-debugscan-retire-eco-r6.pLJ9Sq/closed-rejected-constant-location.sha256`,
SHA-256 `4c1c4e17c99c87f9388cbff991b4e6d9ebca0982abc173f1cbaf5e7aed7eb207`.
The next revision skips coordinate lookup for already-placed matched buffers;
the logical sampler and scan ABI remain identical. Its full route/DRC and
after-routing preservation checks are still required before deployment.

That revision constructs all573 new diagnostic primitives and1736 selected
inputs, then writes a prepared **unqualified** checkpoint. The constant-net
routing operation reports incomplete guidance for two global clocks and two
node overlaps, and rejects before selected-pin routing or the final preservation
audit. It closes **native1/input-pins0**; there is no bitgen or deployment.
Prepared SHA-256 `7a799797da57bd1263d8d3da865ecd09f9b224f718ff01ae05bfd5b76bc638e3`
is a rejected diagnostic input, never an accepted implementation. Seal:
`ventium-debugscan-retire-eco-r7.w6F64J/closed-rejected-clock-routing.sha256`,
SHA-256 `91581e7c08beef2020ca3c55ab508e143567b722c96419c1d8e4275ec0ad7b04`.

A separate bounded clock-guidance probe uses that prepared checkpoint only
for diagnosis. Both new sampler C and R distributions originate at BUFGs in
this native design. The probe tests `update_clock_routing -pin` only on the
468 new C/R inputs, never clearing an original route or moving an original
cell. Any removal of an inherited clock node/PIP rejects the probe. It cannot
write a checkpoint or bitstream, and even success does not qualify the full
observer, CPU behavior or timedemo. AMD documents the unrouted-pin form and
post-placement clock-load updates in
[UG835](https://docs.amd.com/r/2023.2-English/ug835-vivado-tcl-commands/update_clock_routing);
the actual installed2025.2 command and native results, not that older manual,
must establish whether this narrowly scoped approach works. Four successful
per-pin calls show that each call rebuilds the whole affected global tree
(about10–16 seconds each). The redundant first probe is deliberately stopped:
**native143/input-pins0**, no checkpoint/image. Seal:
`ventium-retire-clock-guidance.lGXrQw/closed-stopped-redundant-guidance.sha256`,
SHA-256 `87df2eb32bc83b63d9e6dc1e546323d89130cd2d1fc3963376c5d8f7bd092065`.

The separately named probe makes only one new-pin call per changed global.
Both return0, but routing again reports the same two overlaps. The inherited
C-tree nodes/PIPs survive its subset check; C remains `CONFLICTS`, and the
probe rejects before checking R or reaching any final verdict. This is
**not** a clock-guidance repair, full preservation proof or CPU finding.
It closes **native1/input-pins0**, without a checkpoint/image. Seal:
`ventium-retire-clock-guidance-r2.1hPwTv/closed-rejected-guidance.sha256`,
SHA-256 `2743d53a8455ba3e1f84a1f06682911bc788803b7ecba1492de9c8f36fea8aec`.
An independent read-only inventory requests detailed conflict nodes from
the unchanged prepared input. The clock warning alone does not identify which
resources collide; `-physical_nets` routes constants, not clock nets, as
[AMD documents](https://docs.amd.com/r/2024.1-English/ug904-vivado-implementation/Using-Other-route_design-Options).

The read-only report closes **native0/input-pins0**, but the full report lists
78 resource-conflicting nets while its `-return_nets` helper returns none.
That helper is not a complete conflict-coverage gate. The detailed report
identifies two invalid new sites, `SLICE_X67Y236` and `SLICE_X92Y298`, and
conflicts where external replacement D routes meet old debug response slices.
Seal: `ventium-retire-route-conflicts.qtWXsU/closed-readonly-reports.sha256`,
SHA-256 `ff5e7909ba882d1ae3964b038544e9869273e29f877ef5879456a360c703a23f`.

A separate **unchanged qualified-parent** inventory closes native0/pins0 and
passes its independent data-only consumer. Both sites have `IS_USED=0` and
no primitive occupants or used site PIPs, yet `HAS_PROGRAMMING=1`; the second
also has five inherited routed site-pin owners. Thus `IS_USED=0` alone is
not physical vacancy. All32 old response FDREs have INIT0, C inversion0,
**R inversion1**, CE/D inversion0 and one exclusive Q-to-PS-FIFO-D sink each.
Their reset is not the sampler's non-inverted core reset. Seal:
`ventium-retire-site-vacancy.nUVSrK/closed-inventory-audit.sha256`, SHA-256
`5f70356e25af7d62fb471df99a07a4617df3286596e5224a65e055f502fb4cbf`.
This diagnoses observer placement/readback hazards, not the processor defect.

The next physical-only plan rejects programmed sites, primitive occupants,
used site PIPs and routed site-pin owners. It keeps every old response D
connection intact, places32 replacement response FDREs with matched final
override6LUT data paths, and redirects only the32 exclusive FIFO D sinks.
Response clock/reset/enable/INIT are cloned exactly, with no extra response
cycle. The unchanged150-bit sampler and338-bit legacy scan ABI now use
266 FFs plus339 LUTs (**605** new diagnostic primitives,1864 selected inputs).
Its offline scan checks pass31,424 cases plus468 identity-buffer truth cases;
the installed vendor FDRE/LUT4 model passes8,323 response checks, including
128 distinct reset/enable/truth combinations. An initial testbench fails
before its first clock because an unchanged time-zero input does not trigger
the vendor LUT event model; the corrected fixture makes real input transitions
without forcing vendor state. The failed receipt is retained. Offline seal:
`ventium-debugscan-retire-eco-r8.2oBeaz/closed-response-tests.sha256`, SHA-256
`a539bbfad7150dd75784ba08bcff63bf9694add76cabfb0341d01c4a75b5faaa`.
That native attempt places all605 primitives, then closes **native1/pins0**
before routing or writing a checkpoint. A new hierarchy-crossing response net
is rejected by `DONT_TOUCH` on the SoC instance; this is an observer-connection
error, not a processor finding. No hierarchy protection is relaxed. Seal:
`ventium-debugscan-retire-eco-r8.2oBeaz/closed-rejected-hierarchy-crossing.sha256`,
SHA-256 `66fe08d799af34622c1e8cd95ceb1af0d6b439f3c50f233eb63eb481e836524c`.

The following revision uses the already-proven first observer's method:
exchange only debug output drivers inside `u_mgmt`, reusing the existing
hierarchy-crossing response wire and leaving the FIFO D connection intact.
Old shadow D is unchanged; old shadow Q is isolated on the fresh internal
wire. No CPU output, old-cell placement or hierarchy protection is changed.
A trusted-procedure mock checks32 exchanges and five rejection cases; the
unchanged dual-bank reader passes its10 tests again. New native gates compare
all original hierarchy protections and require zero invalid-site violations
before routing. Swap-test seal:
`ventium-debugscan-retire-eco-r9.CAFLC2/closed-swap-tests.sha256`, SHA-256
`302c3fc1ff8f0e0dc7fb317e840eba7def1acdd1c7a50e89c776286d60545307`.
The bounded R9 attempt constructs all605 primitives and32 readback swaps,
passes the pre-route invalid-site DRC with zero violations, and completes
constant routing with zero overlaps. It still reports incomplete clock-guidance
metadata, and selected-pin routing fails on one newly added connection:
original LUT6 `u_icache/eip[5]_i_1/O`, `SLICE_X73Y208.CMUX/C_O`, to
`ven_retire_scan_data_pre_5/I0`, `SLICE_X75Y211/F1`. The parent inventory had
that original EIP-D connection as **INTRASITE**, with no intersite nodes/PIPs.
After saving a partial **unqualified** checkpoint, the550-second Tcl budget
rejects before the after-routing preservation audit. Native closes **1/pins0**,
with no bitgen or deployment; failure-time zero-error DRC is not closure.
Seal: `ventium-debugscan-retire-eco-r9.CAFLC2/closed-rejected-pre5-placement.sha256`,
SHA-256 `4536b4491e49d931110e38f201a468032048a09947ebde65697474b3b71282a0`.
Partial checkpoint SHA-256
`8aabc0b08e138659589de581efddb18e5bd3aa9a9d2de3312404e6050de88cce`
is diagnostic input only. The subsequent read-only source/target query closes
native0/pins0 and confirms **225,580/225,581** routable nets fully routed,
exactly one unrouted net and zero routing-error nets. The actual bit5 source
is LUT6/O6, not an O5 or MUXF output. Its C_O and CMUX site-output nodes are
unowned; some escape resources are free, while others belong to CPU nets.
The new sampler's F3 input and all seven immediate predecessor nodes are
unowned. This supports a bounded new-LUT input-map trial, not proof of a
complete path. Inventory seal:
`ventium-retire-pre5-endpoint.z5tP8T/closed-readonly-endpoints.sha256`, SHA-256
`1011421ad04ad2f23bfe93f08b0f37332dda78c221f2bec57ae43953922db5d7`.
There is still no additional deployment, CPU repair or timedemo acceptance.

The bounded same-site F1→F3 remap of only the new sampling LUT is also
unroutable. It closes native1/pins0 without a checkpoint or deployment; the
source/target routing problem is not a processor finding. An earlier
preflight-only attempt rejects before any mutation because a hierarchical
net-filter result does not match the complete native route report. Rejected
F3 seal: `ventium-retire-pre5-remap-r2.IcuPIC/closed-rejected-remap.sha256`,
SHA-256 `e442a146e3310b8c70b7c959fd1c4332dedc9919d77789f6dedac7d114217a39`.

To avoid changing CPU placement/routes just to observe one signal, the next
diagnostic catalogue explicitly marks **EIP-D bit5 UNKNOWN**. Its storage
slot (record bit69) is a zero placeholder, never reported as a measured or
predicted CPU bit. Architectural primary PC, actual next-PC and actual PF
remain fully observed, as do all other sampler inputs. Only the new input
is disconnected from EIP-D; a constant-zero new LUT supplies that storage
slot. A second new LUT changes selector110 metadata to **000f0096**, so the
partial format cannot be confused with the earlier complete-input format.
No CPU LUT, original FF, opcode, pairing rule, clock or guest payload is fixed
or replaced. Catalogue SHA-256:
`2d58b14da4a9ad82ca66155a175e2142997fd72bf0ba767abcce5307544583e9`.
Physical-plan SHA-256:
`2585d406be52caaf25dedb4882a00c03abfa4c62f199f13f1057c8423e9967ed`.

The partial reader passes12 tests (including old-metadata rejection, unknown
slot corruption rejection and selector restoration);31,424 scan-logic checks,
468 buffer truth cases and320 installed vendor-LUT/FDRE checks also pass.
Initial catalogue/wiring and vendor-global-model fixture failures are retained,
not counted as passes. Offline seal:
`ventium-retire-masked-input.IRmCT2/closed-offline-mask-tests.sha256`, SHA-256
`b11e025aa431a3707a38bc7d864b667cbf076a516909f6d11046fedb79cb9908`.
An initial native preflight rejects before mutation on case-sensitive INIT
comparison; the next native query confirms hexadecimal letters are uppercase.
Comparison is normalized without relaxing function/placement/pin-map checks.
The update then closes **native0/pins0**, with **225,580/225,580** routable nets
fully routed, zero routing errors and zero full-DRC errors/critical warnings.
It changes only two new diagnostic LUT INITs and one new input connection;
all inherited POWER nodes/PIPs from its input are retained. Route-only seal:
`ventium-retire-masked-eco-r2.dl55kM/closed-masked-route.sha256`, SHA-256
`e51c18219a8ad81ae6c251caa436c7023fbdd4c94d52bd3c67b7960b42d5cc5a`.
Checkpoint SHA-256:
`265fdac8f5ef56e5c6e8a3b06eac526f2d448cb4f8e2d1aef064230d19e87298`
then passes a separate, read-only comparison against the qualified parent:
297,551 original primitives,235,916 original FD input inversions,329 original
hierarchies,4,119 original LUT pin maps,225 source/sink groups and193 inherited
source-resource groups. All605 new cells/1864 inputs,234 matched sampler paths,
32 matched response paths and128 originally vacant sites are checked. The
full route partition is **415,558** unchanged literal routes +**224** tapped/
debug exceptions +**471** constant aliases =**416,253** original groups.
The GND tree is literal-identical and all original POWER nodes/PIPs are kept.
Full routing and DRC pass again; native closes0/pins0 and the independent
sealed-record consumer passes. An initial read-only audit fails its own
partition accounting after comparison because the tapped constant root was
also counted as a signal exception; the corrected helper passes five directed
cases and the entire native audit is rerun, without relaxing preservation.
Full-parent-audit seal:
`ventium-retire-full-parent-audit-r2.htKx0f/closed-parent-audit.sha256`, SHA-256
`d962c63f26e5e2d134bfb6abc0fe0d146e062ff68fcd8c710f3b506b84f222f8`.
**This qualifies only diagnostic graph/route preservation, not STA, silicon
correctness, a CPU repair or timedemo acceptance.** The separately qualified
bitgen, deployment and direct retirement capture are recorded above.

Native collections are not generic Tcl lists; preserving their object type
matters when passing them back to native APIs. This is consistent with
[AMD's collection-handling guidance](https://docs.amd.com/r/2022.1-English/ug894-vivado-tcl-scripting/Handling-Lists-of-Objects).
The exact errors, cache repair and native preflight results above come from
these pinned2025.2 runs, not a claim that documentation alone qualifies an ECO.

Board cleanup removes only the closed `mFdR81` and `XEIuht` private runs and
their duplicate board exports, after re-auditing both host recovery captures,
closed native invocation identities and every original/export file. It frees
109,256,704 bytes;264,998,912 bytes are available afterward. The latest
`KILHpq` control, production media, firmware, rollback and VHD seed are kept.
Complete captures remain under `ventium-private-observer-controls.BFWmEY`
and `ventium-private-observer-boundary.cj7i9A`; the omitted private VHDs match
the retained seed. Cleanup closes0 and its independent host audit passes.
Seal: `ventium-board-archived-cleanup.fyTzpg/closed-cleanup.sha256`, SHA-256
`d42a30898f27510a262bbaf9a5f5d9dca401decb738e1631df904b1144cf74de`.

Obtain causally useful retained-packet/next-PC evidence before selecting
a general fix. Do not disable pairing, single-step production Quake, suppress
faults, or patch its allocator to manufacture completion. Any eventual major
core/cache change must pass differential gates and the entire standard suite:
both CoreMark correctness seeds, Win95 boot-to-desktop, and completed Quake
timedemo. A 64-case private pass does not discharge that requirement.

## October6 calibrated branch-decision capture — not a processor fix

The new debug-only BIN is
`48288e836e9347b4ff80638c972602d5c4aa5874d8b23bb61c6e47a15820838f`.
Deployment closes0 and the independent host deployment/clock audit passes.
With reset held and zero retirements, five seconds of counter/time arithmetic
measure **39.999878619MHz**. Production BIOS, disk and all eight production
pins remain unchanged; original and previous observer rollback images remain
on the board. This is not gameplay, a CPU repair, or40MHz production acceptance.

The observer reuses the previously constant-zero missing-EIP-D-bit5 slot:
record bit69 now captures the actual mapped `v_br_taken_eff` output at
`u_core/u_core/u_icache/rt_use_i_3/O`. **It is not EIP-D bit5.** EIP-D retains
known mask `ffffffdf`; length bit3 is still unknown. Selector110 metadata is
now **002f0096**, catalogue SHA-256
`e9adc9491b4a3ed25e3e0d4402e12cdd7f1be3d0d4ce8159c4787ea24eaca5ee`.
The new reader rejects the old format and independently clears bit69 out of
the reported partial EIP-D value. Its13 fake-MMIO tests,150 retirement and338
legacy one-hot cases,256 metadata cases and128 installed vendor-primitive
cases pass. These qualify observer logic, not processor correctness.

Two same-input F1-endpoint trials close native1/pins0 as unroutable, without
a new checkpoint/BIN or deployment: effective-PF tap
`ventium-retire-effective-pf.o9MU17` and branch-decision tap
`ventium-retire-v-branch.xo1PyW`. Their receipts are retained. The successful
bounded trial changes **only** two diagnostic LUT INITs, one diagnostic input
connection and that diagnostic LUT's physical input mapping **A1→A3**, at the
same site/BEL. No new FF/LUT, CPU functional change, old-cell movement,
clock/reset change or full synthesis/place/route occurs.

Native route preservation and a separate read-only canonical-constant-tree
audit close0/pins0. All298,156 primitives,236,980 FD input inversions,
329 hierarchies,44 source pin maps and560,525 literal old nonconstant routes
are checked. The original branch signal's38 sinks and168 nodes/167 PIPs are
kept, with one observation sink added. POWER70,944 nodes/57,982 PIPs and
GROUND106,722 nodes/103,141 PIPs are literal-identical. Full routing and DRC
have zero errors/critical warnings. Native bitgen then closes0/pins0, emitting
a20,606,636-byte raw BIN, byte-identically renamed with no bootgen/byte swap.
Preserving existing route branches does **not** prove zero electrical
perturbation from the extra load, timing closure or transient-free capture.

Three cold private controls now have coherent halted scans,16MiB physical RAM,
zero104-byte exception records and independently audited closed native0 /
controller0 / launcher0 results. No STEP, intended-V breakpoint, guest repair,
save-state, pairing disable or clock change is used. Breakpoints name only the
result boundary and capture before a subsequent instruction or fault.

| Capture at40MHz | Actual case | PF-D/Q | Captured V branch decision | Actual next-PC | Partial EIP-D (`ffffffdf`) |
| --- | ---: | --- | ---: | --- | --- |
| Original memory-left CMP/JP, bad boundary | 2 | 1/1 | **1** | **14566 (wrong; expected1457a)** | 14547 |
| Same original ROM, healthy not-taken boundary | 0 | 0/0 | **0** | 14567 | 14547 |
| Previously QEMU/model-qualified OR/JP ROM, healthy taken boundary | 2 | 1/1 | **1** | 1457a | 1455a |

All three records report primary PC14562, state28, ACTIVE0, EIP-CE1,
U/V length low bits3/2, V conditionA and displacement13. The first and third
have retained owner14558; the not-taken control has retained owner1455d.
All eight retained ACTIVE copies are0, so these older retained packets must
not be mistaken for the live failing packet. The independent consumers decode
raw sampler bits as data, separately from the deployed reader, and check the
actual primary/EIP/PF against unchanged architectural scans.

The healthy cases calibrate both0 and1 through the same tap, metadata and
two-edge reader protocol. The failing run reproduces the original
count2/caller3/checksum9fff, FLAGS887 and actual EIP14566 before ADC/#PF.
Thus a **captured static false JP decision alone does not explain this run**.
The partial EIP-D equals masked14567, whereas actual Q is14566: known D/Q
xor1 persists. Healthy not-taken and OR-taken captures have known D/Q xor0.
PF-D is still the architectural flags-register D input, not a new effective-PF
tap. The additional tap is the combinational branch decision, **not** admitted
`do_v`, V-retire-valid, final redirect select or a target-word capture.
Clock skew/transient propagation and capture alignment remain possible;
the new observations do not establish what every CPU FF sampled on that edge.

### Closed evidence and recovery

All directories are under `/home/yukidama/external/tmp/`.

| Capture root | Native invocation | Files in capture manifest | Capture manifest SHA-256 |
| --- | --- | ---: | --- |
| `ventium-v-branch-fault.OMP3dz/exception-log-DeB5aS-export` | `3e38c500b6fc4b178c12f8e48ac8809a` | 44 | `7c1dc88e191e6ec8d387de5811800972b0946dc8758f6b9c8c2730f3782bf4dc` |
| `ventium-v-branch-nt-control.aUOpHv/exception-log-sCrrN4-export` | `aa464c179d21403db848308a7004b251` | 43 | `631214ec4b80d9ae593ff4bfe333f2eb459a33b8270b265835367835ea4dff60` |
| `ventium-v-branch-taken-control.NBSGG7/exception-log-3gD63l-export` | `4d96b6abbaa4497cafb81d108db4fe58` | 43 | `b5d3f05e1484c4c90b0d0c6f3c957f8130179aa14a0f93df34dc28783a234c6c` |

Each parent root contains an independent `audit-result.json` and
`closed-vbranch-audit.sha256`; seal SHAs respectively:
`c73225d35cbad23f785ee7ae8eaffaed1bf7efec824b8d6b80795a659530302e`,
`2ed92363dbac645286b5cfd4834e38678ec334e38459d97be87bf61227b20857`,
`fe50c925ab20f89cf994d17c1e9d658fdb476d04af6a1fbc2b5605792e0d3fe7`.
Route preservation seal:
`ventium-retire-v-branch-a3.5ZgLVb/closed-route.sha256`,
`7665ca59bd3b4efc46b3d1504c1d5df165cba5800dc5a77af8105e2cd18319e4`.
Routed DCP SHA-256:
`a69cd157a99a4cee0e42bf902aa6e60a0f802b6bfdece851ebe20319894ffa5a`.
Constant audit/bitgen seal:
`ventium-v-branch-bitgen.nCsJlP/closed-bitgen.sha256`,
`1c53e924b5ee51602e2654de44d23a57cac687db8e0fba64672f7e5052c2eb28`.
Deployment seal:
`ventium-v-branch-deploy.nn4nEW/closed-deployment.sha256`,
`fd06677dff568c9d8d26f8c639106c4b62e449e8118f35a2e34a61ed0c7dfa96`.
An initial recursive deployment retrieval returns1 on unreadable empty marker
directories; the explicit flat-file retrieval closes0 and all archived inputs
and native raw BIN are independently hash-checked. A later log retrieval has
one hostname-typo failure, followed by an explicit successful retrieval;
neither causes another FPGA program or guest run.

Board capacity remains limited. Only exact, closed and independently archived
duplicate exports and seed-identical private disks are pruned. The new failing
run's archived16MiB RAM file is also removed from board RAM-disk after checking
its exact hash, closed invocation and no open owner; complete RAM is retained
on the external filesystem. Original metadata/logs, production media and all
rollback images remain. Sparse VHD logical size is **not** reclaimed allocation:
67,092,480 logical bytes per duplicate are not a67MiB free-space claim. Original
once-only launch failures at capacity admission are retained; no native worker
starts in those attempts. The successful controls remain bounded to60 seconds.

### Remaining discriminator and proposed general fix direction

Use mapped physical inputs to bind and distinguish pairing admission,
U-branch priority, V target/fallthrough, final redirect and PC-update selection.
The existing architectural scan stops at selector75 and has no V-retire PC;
the PC ring/PMU also export primary retirement only. Do not treat either as
proof that V committed.

The bounded read-only dispatch-cone query now closes native0/pins0 and its
independent data consumer passes:33 roots,363 cells and2405 pins, including
all276 cells/1756 pins from the preceding query byte-identically. Its72 finite
control truth cases establish the actual mapped `u_icache/eip[14]_i_17/O`
function:

```
U_branch ? (U_pred || U_taken) : dispatch_gate && (V_pred || V_taken)
```

The mapped dispatch gate is `rpc_use[31]_i_3/O`, the AND of
`gpr[1][29]_i_12/O` and effective V `is_branch` (`rv_use_i_3/O`). These names
are bound by physical primitive inputs, not guessed from display aliases.
This is a useful downstream sampling point, **not an observed runtime value**
or a proof of the whole PC cone. At U_branch0 and V_taken1, that select still
depends on dispatch_gate; the calibrated branch tap alone cannot establish it.
The query changes no design/constraints, writes no DCP/BIN and does not program
the board. Recovery: `ventium-nextpc-dispatch-cone.xqDoO2`; native query seal
`4723633f47470840a4ab0f26ce2203067bcdcf6b985512039a8930658b072804`,
independent analysis seal
`f51b1c3acc2c27d5ddf6d86e9c3b795b791b28bf50f6727975b1929b076569c9`.

If a descriptor/admission mismatch is established, fix the ownership/lifetime
contract for the immediate memory-response path, with exact-address/epoch
microtests. If target/redirect selection is wrong, centralize generic U/V PC
advance and target calculations, sharing one admitted packet and preserving
16-bit wrap, both prediction outcomes, page crossings, interrupts/debug holds
and all Jcc conditions. If propagation is established, shorten the sensitized
operand/flags/branch/PC cone or compute targets earlier in parallel; do not add
blanket bubbles, disable pairing or patch the guest. These are conditional fix
directions, **not** implemented or proven fixes. Differential gates and the
complete standard suite are still required after a major functional change.

## October6 calibrated downstream PC-selector capture

**The bad CMP/JP boundary also captures the downstream mapped selector as1.**
Healthy not-taken and OR/JP-taken controls independently calibrate0 and1 on
the same deployed image. This narrows the next investigation to selected PC
data, subsequent update selection and propagation/capture alignment; it is
not a processor repair or proof of a timing cause.

The debug-only image is
`a533550b2cbd527aebee8effa2765ff3736ea209c9aa49d5b29797e81d7d81f9`.
It observes `u_core/u_core/u_icache/eip[14]_i_17/O`, the actual mapped LUT6
with INIT `64'hEEEEEEEEF0F0F000`, at `SLICE_X20Y239/SLICEM.H6LUT`.
Its finite truth function is the U/V selector recorded above. It is **not**
the final EIP-D word, an actual `do_v` observation, or proof that V retired.

Record bit69 now means `previous_edge_mapped_pc_selector`, metadata
selector110 is **004f0096**, and catalogue SHA-256 is
`d647facd1ccb3104f137e03ae5774bfb497b7f619c2f0817b9c5f36a49113937`.
EIP-D bit5 remains **UNKNOWN** and is excluded with mask `ffffffdf`.
The reader rejects the preceding branch-tap metadata;14 reader tests,
150 retirement/338 legacy one-hot cases,256 metadata truth cases and128
installed vendor-primitive cases pass. These are observer tests, not CPU gates.

Only two diagnostic LUT INITs, one diagnostic input connection and the
diagnostic sampler's A1→A3 pin map change. No primitive is added and no CPU
function, placement, clock/reset or original LUT pin mapping changes. Native
preservation checks cover298,156 primitives,236,980 FD input inversions,
329 hierarchies,39 source pin maps and560,525 literal old nonconstant routes.
The selector's32 original sinks and123 nodes/122 PIPs are retained; one
observation sink is added. A separate read-only constant-tree audit confirms
POWER70,944 nodes/57,982 PIPs and GROUND106,722 nodes/103,141 PIPs unchanged.
Full routing/DRC and native bitgen close0/pins0. No full synthesis/place/route
is launched. Retaining old routes does not prove no added-load perturbation.

Deployment and its independent host audit close0. Held-reset counter/time
arithmetic measures **39.999876587MHz**, with zero retirements. All eight
production pins pass again after the controls. The raw20,606,636-byte BIN is
byte-identically installed, with no bootgen/byte swap; prior images remain.

| Cold private capture at40MHz | Case | PF-D/Q | Captured mapped selector | Actual next-PC | Partial EIP-D (`ffffffdf`) |
| --- | ---: | --- | ---: | --- | --- |
| Original CMP/JP, bad boundary | 2 | 1/1 | **1** | **14566; expected1457a** | 14547 |
| Original ROM, healthy not-taken | 0 | 0/0 | **0** | 14567 | 14547 |
| Qualified OR/JP, healthy taken | 2 | 1/1 | **1** | 1457a | 1455a |

All three have primary PC14562, sampled state28, ACTIVE0, EIP-CE1,
U/V length low bits3/2, V conditionA and displacement13. All eight retained
ACTIVE copies are0; retained owner14558 for fault/taken and1455d for not-taken
still belongs to an older packet. Their partial EIP-D/actual-Q known-bit XOR
is1 for the fault and0 for both healthy controls. The expected target is
`14562 + 3 + 2 + 13 = 1457a`; neither unknown EIP-D bit5 nor unknown length
bit3 is fabricated by the consumers.

Each capture has44 hash-pinned exported files,16MiB physical RAM and a zero
104-byte exception record. Native, controller and launcher all close0;
independent consumers re-decode raw150/338-bit packets separately from the
deployed reader and compare architecture, code, ROM, mapping, scalar records
and native invocation identity. No STEP, guest patch/save-state repair,
pairing disable, intended-V breakpoint or clock change is used. The healthy
OR ROM is a private opcode discriminator, not a production modification.

All following paths are beneath `/home/yukidama/external/tmp/`:

| Capture in `ventium-pc-select-captures.nUrour/` | Native invocation | Capture manifest SHA-256 |
| --- | --- | --- |
| `exception-log-rDhCM9-export` | `939d028946cc45e8a6e434febd1fcc9f` | `67f5b16079e4aef923f08642aaefb2513d8b3b1b23474855aa685b2914673049` |
| `exception-log-ueIyd5-export` | `1788e21cabd24b9d90685c4d24772afd` | `48b108d90232c431b26636a1d37961246190d49e02c6b10504ed6083efdeef9d` |
| `exception-log-KYP24e-export` | `0e9dc0123c4844b2b182299f6db135b6` | `dfece4b2dfbd3aaf7a16b38b70806aac53fe16b92d118871f70e207d47f772ae` |

The parent contains the three `*-independent-audit.json` receipts,
`deployment-audit.json`, original transport/source pins and cleanup receipts.
Its207-file `closed-pc-select-captures.sha256` verifies with SHA-256
`fd66fa300097db16cfd85bdf445edaa13d1e4016234c3ad2b79be3cc75af0ab7`.
Route qualification: `ventium-pc-select-observer.n3UmUG/closed-route.sha256`,
`3ad0437e369d855ce1209b058bcd9ffeee2d5a685606a833de4015cf3a4869d2`;
routed DCP `0ca9266f4ede85f7981b05b35353a47f995e057a6b81b42a74d821a2a0222c30`.
Constant audit/bitgen: `ventium-pc-select-bitgen.LQdTty/closed-bitgen.sha256`,
`3ce2bbf0033026a54355c19bc42d0994bc438565f42cbc8d5649ff1f7ea86561`.
The initial fake-MMIO receipt fixture and relative-manifest preflight failures
remain archived; corrected runs close0. The latter starts no Vivado process.

After complete host retrieval and independent audits, exact closed fault/NT
duplicate exports, seed-identical private disks and archived physical-RAM
copies are removed from board RAM-disk. Each removal frees54,202,368 allocated
bytes; complete captures remain recoverable on the host and original board
metadata remains. The latest taken capture, production media and rollbacks
are kept. The staged upload BIN is also removed only after installed/host
hash agreement and successful deployment/retrieval; installed firmware stays.

**Next fix discriminator:** evaluate the mapped selected-target/fallthrough
data and final PC-update muxes, with the memory-CMP versus OR control held
explicit. Do not change pairing/flag forwarding solely because the fault
follows CMP: both the earlier branch decision and this downstream selector
capture1 in separate faulty runs. These are not simultaneous observations
on one image/edge, and do not exclude a transient or a capture-skew effect.
Any general fix must preserve admitted packet ownership, all Jcc outcomes,
code16 wrap, debug/interrupt holds and cold production behavior. No CPU fix,
new gameplay IPC or40MHz cold production timedemo acceptance is claimed.

Verified gameplay remains **0.1659957781052303 primary/U IPC**, image
`53f129e9` at37.499869764MHz,127 independently qualified active intervals
with gaps spanning cycles8,721,490,845–19,169,282,165. It predates this
observer; `a533550b` has no gameplay measurement.

### Read-only PC-data cutpoint miter

The follow-up query opens the actual deployed observer's routed checkpoint
read-only and closes **native0/pins0**:60 roots,496 primitives and3197 pins.
All preceding363 primitive/2405 pin records are literal-identical. It writes
no checkpoint/BIN and changes no route, placement or clock constraint.
Recovery root: `ventium-pc-data-cone.XG4N30`; native seal
`97d0716c355983b24d0665217d9c709baa6f15c9ad75ef2190a981c2a513ea85`.

The independent consumer verifies actual primitive inputs/INITs and passes
512 live/retained ownership and target-LSB arithmetic cases,32,768 stable
taken-V mux-LSB cases and8 ideal S_PIPE primary-PC mux cases. It keeps
prediction and unused side-word inputs arbitrary. Original EIP bits0/1 have
non-inverted C/D/CE/R, so an omitted D-input inversion is not the observed
known-bit D/Q xor explanation. **This is a low-bit cutpoint check, not proof
of the final PC mux, whole target word or simultaneous runtime values.**
An initial consumer assertion incorrectly expects CI and CI_TOP to name the
same GND alias; the two exact native aliases are asserted separately in the
corrected run. The failed fixture receipt is kept. Analysis seal:
`f539f2f3915e1593e2d55417bd1f4e1457c2256bf064082658fa387d07534451`.

The targeted path reports include the requested branch/selector and actual
EIP-bit0 endpoint in their resource bodies. Their longest reported path is
48.505ns,111 logic levels,77.431% routing, beginning at a segment-base FF and
passing cache/decode logic; at the modeled slow corner its reported setup
budget corresponds to approximately20.6MHz. **That is not measured Fmax or
proof this path is sensitized by the fault.** Measured core clock remains
39.999876587MHz. The segment base is fixed during the private cases; using
the overall report as the fault explanation would be unjustified. Native
command headers reconstruct nested pin queries misleadingly, so the
consumer verifies actual resource names in both paths of each report.

The next diagnostic should capture branch decision, selected-target LSB and
successive PC-mux outputs **together on one image/edge**, while retaining
the original D/Q and selector observations. This avoids treating separate
one-bit captures as simultaneous evidence. No CPU patch or extra full
production run follows the static miter alone.

### Simultaneous PC-vector diagnostic — CPU functions unchanged

The next image reuses nine existing high-relative-displacement observer slots
to sample the branch and successive PC-data cutpoints in the same two-edge
bank. It keeps the original mapped-selector slot69, architectural D/Q fields,
150-bit retirement bank and338-bit retained-packet bank. It adds no FFs/LUTs
and changes no CPU function, site/BEL, clock, reset or record-enable logic.

| Record bit | Mapped point sampled on the preceding edge |
|---|---|
|119|U_IS_BRANCH|
|120|V_BRANCH_TAKEN|
|121|V_TARGET_LSB|
|122|V_FUSED_INVERTED_LSB|
|123|PC_TARGET_LSB|
|124|PC_PRIMARY_LSB|
|125|PC_STATE_MUX_LSB|
|126|PC_FP_OVERRIDE|
|127|U_ADVANCE_LSB|

Metadata is now `008f0096`, catalogue
`7208a32a09f7294f98135dcf110054a85cef6dc42bbf092b620d2b7fcb31b215`.
EIP-D bit5 remains unknown (`ffffffdf` mask). V-relative bits23–31 are now
**unknown** (`007fffff` mask); the reader reports the full displacement as
null, not a reconstructed signed value. Offline tests cover150/338 onehots,
512 vector patterns and2048 metadata cases. Installed vendor models pass
128 changed-metadata checks and2048 reset/hold/two-edge vector cases. None
of these tests proves routed settling times or processor correctness.

The first route-only attempt closes native1/pins0 and is rejected: retaining
all old branches leaves nine antenna endpoints belonging to disconnected
observer inputs. It writes no checkpoint or bitstream. Recovery root:
`ventium-pc-vector-observer.f41xtL`. The revised, documented selective
unroute removes only those observer-input paths back to their nearest branch.
Its independent consumer confirms removal of89 observer-only nodes/87 PIPs,
with every retained CPU sink path preserved. All298156 primitive identities,
236980 FF-input polarities,329 hierarchy protections,2336 original physical
pin maps and560440 non-target route literals are unchanged. Only two
metadata LUT INITs and nine observer input mappings/reconnections change.
Native0/pins0, fully routed, zero route errors and zero error/critical DRCs;
route seal `cb33367875e9ed2d561a20cad35ddffd42e39475cf460eacf04c798fe4a91d7b`
under `ventium-pc-vector-observer-r2.xUZ2Ld`.

Separate bitgen reopens parent/candidate and checks exact canonical POWER
70944-node/57982-PIP and GROUND106722-node/103141-PIP trees, including their
route literals, plus all nine bindings and unchanged25ns/10ns clocks.
Native0/pins0; raw BIN remains20606636 bytes with native sync at offset80.
Firmware SHA `74d7cf7d8c24c87da025696d0f19c719ea689bc717de123ba5d98d65a765ced9`;
bitgen seal `89aa7c03cc7322111a776084c45f3eca3f63c7fd52fb0395dffdfcffcb7ec0f3`
under `ventium-pc-vector-bitgen.LvID7D`.

Deployment closes0 and the independently retrieved receipt measures
39.999875259MHz with zero retirements during admission and all eight
production pins unchanged. Sources/archive: `ventium-pc-vector-captures.W1DCH1`.
The seed, production inputs and all installed rollback images are retained.
Already closed/independently archived KYP24e duplicates and the old sCrrN4
RAM duplicate free70979584 allocated bytes; their original metadata and host
archives stay intact. The separately archived/installed upload duplicate
frees another20606976 bytes. No unique evidence is discarded.

Same-bank sampling does not establish equal analog arrival times: added
tap load and differing routed delays/capture skew may perturb reproduction.
Cold private faulty/healthy controls must qualify the values before attributing
the failure. No CPU fix or40MHz cold production timedemo is accepted here.
Verified gameplay remains0.1659957781052303 primary/U IPC on `53f129e9`,
37.499869764MHz,127 active intervals with gaps spanning
cycles8,721,490,845–19,169,282,165. It predates `74d7cf7d`, which has no
gameplay measurement.

#### Closed simultaneous faulty/healthy controls

All three private cold controls close native0/controller0/launcher0 on this
same image. Each44-file export passes the independent byte/hash, invocation,
production-pin, architecture, RAM, reset-bank and retirement/retained-bank
audit. Captures are taken before ADC/#PF or late forensic reset; no STEP is
used and the intended V-slot address is not the breakpoint.

| Observed point | CMP/JP fault | CMP/JP not taken | OR/JP taken |
|---|---|---|---|
|Primary PC|14562|14562|14562|
|Actual next-PC Q|**14566**|14567|1457a|
|PF D/Q|1/1|0/0|1/1|
|V branch taken|1|0|1|
|Mapped selector|1|0|1|
|Selected PC-target LSB|0|1|0|
|Primary PC-mux LSB|0|1|0|
|Later state-mux LSB|**1**|1|0|
|Partial EIP-D, maskffffffdf|14547|14547|1455a|

U_IS_BRANCH and PC_FP_OVERRIDE are0, U_ADVANCE_LSB is1 and V_TARGET_LSB
is0 in all three captures. Thus the latter point is **not** calibrated with
both logic levels. V_FUSED_INVERTED_LSB is1/0/1. The sampled raw main state
pattern is28, ACTIVE is0 and EIP-CE is1 in every capture. Known U/V length
bits are3/2, conditionA and V-relative low23 bits13(hex); high9 displacement
bits remain unknown. All eight retained ACTIVE copies are0. Stale retained
owner14558/1455d/14558 is not substituted for the live-selected packet.

Recovery captures under `ventium-pc-vector-captures.W1DCH1`:

- Fault: Xq8wx3, invocation `77913c8cc6b0434bbcd4486d57cbc29e`, manifest
  `689505c18829fe2543d3cfa49fd953771d08f3361385578400c659d1db69c7ab`.
- Not taken: axjvxg, invocation `5c63aca24dd74e809ed0cd919cc3f18c`, manifest
  `c83653712c559cf2180612b18b9bbe76fcd13cd59cf584f9a2fc545caee6d4bb`.
- Taken: HxMri6, invocation `c6e2141bd1554ffc9a6b2c0a9d7639fe`, manifest
  `873f62c56e04cef7e479b82ef7d2a5b42afd8f29477a6b6e9c843e12e8527716`.

The212-file host seal is
`8e408202f0f1fcd6bfc5275b803ddefc73016c358b15f317decc4325ad33486b`.
After complete retrieval/audit, only fault/NT board duplicates are pruned;
their original metadata, full host exports, seed and firmware stay available.

**Interpretation:** the fault reproduces with branch decision/selector and
earlier selected-PC low bit matching the healthy taken case on one image.
It differs at the sampled later mapped mux. This narrows the next check to
that mux's controls/arrival times and the observer's own capture latency;
it is not proof of a stable Boolean defect, replica disagreement or clock
skew. In particular, the faulty actual next-PC's LSB is0, as is1457a's:
this diagnostic does not yet localize the actual incorrect word bits2–4.

The DATA-only follow-up passes two conservative set-valued low-bit miter
cases through the later mux and final EIP-D LUT, allowing all other data
cutpoints arbitrary. It assumes19 referenced state-replica outputs agree
on raw pattern28, reset is deasserted and primary-PC/FP-override inputs are
stable. Under those assumptions, final/mux LSB equals primary-PC LSB; both
healthy captures agree and the faulty sampled mux differs. Actual replica
agreement and analog settling are **not** verified. Their FDRE/INIT0
identities are present in the native data; names alone do not prove polarity
or runtime agreement. Miter output hash:
`595e32ee8c75ca0dc8db782962b386879f2242810105d36ce4a5467e07a61838`.

**Proposed fix direction, pending discriminator:** if ownership/priority is
wrong, make the admitted packet's PC commit carrier and valid selection
explicit, including memory completion and interrupt/debug holds. If physical
arrival is responsible, factor the equivalent state/PC selection into a local
low-fanout, packet-owned path; first prove equivalent outcomes across all
states, exceptions and code16 wrapping. Neither case justifies disabling
pairing, adding unconditional bubbles, guest patches or a Quake-only bypass.
Any CPU repair still requires differential gates and the full standard suite.
No processor fix, new gameplay IPC or40MHz production timedemo is claimed.

#### State-register controls and observer endpoint delays

A subsequent read-only query on the deployed observer's routed checkpoint
closes native0/pins0 and passes the independent DATA consumer. It requests
all seven main state bits plus the17 other registers referenced by the low-bit
miter:24 FDRE/INIT0 registers. Every replica has the same clock, enable and
reset driver and input polarity as its corresponding main bit; D inputs are
non-inverted. Seven replicas have differently named D-driver LUTs. Their
functions and runtime Q agreement are **not** established by these records.
Names alone do not establish opposite polarity or an incorrect replica.

The72-cell/320-pin query also verifies all nine existing two-edge observer
chains and12 requested PC endpoints. CPU EIP bit4 is FDSE/INIT1, correctly
using synchronous set rather than reset; its input polarities are non-inverted.
All31 endpoint net-delay objects are native, non-estimated modeled delays,
with exact net/to-pin identities and units **picoseconds**.

| Endpoint | Fast min/max (ps) | Slow min/max (ps) |
|---|---|---|
|Original EIP-bit0 clock|1419/1585|2323/2597|
|Primary-PC observer clock|1367/1532|2234/2496|
|Primary-PC observer input net|581/762|776/1140|
|Later state-mux observer clock|1439/1606|2363/2627|
|Later state-mux observer input net|661/871|842/1271|
|Primary output → state-mux input|550/723|722/1072|
|State-mux output → final-D input|279/365|334/524|

These are endpoint **net/site** delays, not total logic-path delays, measured
arrival phases, setup/hold margins or measured Fmax. Observer buffering and
its own capture skew remain relevant. Different modeled delays neither prove
nor disprove the silicon failure's cause. The checked state-clock endpoint
slow-min values span2237–2423ps and slow-max2491–2705ps; this does not prove
runtime state disagreement. No routing, constraints, CPU RTL or firmware is
changed by the query.

Recovery root `ventium-pc-state-capture-query.yVG6kH`; closed-query seal
`954ff81049a37e5962cd72f78ea59dbc45435c99a968ca0c5f4cc081a74ad9d6`.
Independent audit hash
`42ac564f1e4d5169b57fe23c55fdf112309b1045a52d031d1f6bc7e6441e54b5`.
Failed consumer-schema assumptions and corrections are retained; no failed
fixture is reported as a hardware pass. The next read-only check compares
the differently named state-D functions before any CPU repair is proposed.

That follow-up closes native0/pins0:10 D-driver roots,161 cells and922 pins,
four mapped fanin levels, with no checkpoint or bitstream output. The exact
literal-clone proof establishes all seven differently named state-D drivers
are Boolean-equivalent for **arbitrary physical input values**, without
assuming any state Q agreement. Five pairs have identical INIT and ordered
input-driver pins directly. The two bit0 replicas instead use a duplicated
LUT pair (`env_tmp[0][15]_i_9` / `ic_ptag[0][1][18]_i_2`) whose INIT and
ordered inputs are themselves identical; substituting that proved equivalence
makes their final state-D LUTs identical as well.

Together with INIT0 and matching C/CE/R controls, this verifies ideal digital
replication for the24 checked registers. It rules out a stable **function or
polarity** mismatch in that subset, not physical setup/hold violations,
transient hazards or the values sampled by separate routed observer paths.
An eager BDD consumer hits its resource cap; a common-cutpoint abstraction
is then inconclusive. Neither failed consumer is a CPU counterexample or
pass. Exact literal-clone congruence is the final, simpler proof.

Installed vendor LUT6 models independently pass2240 domain cases for the
duplicated intermediate function and all three D-driver function classes.
The first vendor bench fails because its unchanged all-zero initialization
does not trigger the vendor model's input-event block. A fresh r2 bench
explicitly toggles inputs before enumerating the same cases; expectations,
models and INITs are unchanged. Both failed and passing fixtures are retained.
This cross-check is functional, not routed timing or silicon acceptance.

Query/proof root `ventium-state-replica-functions.jPiKVU`, seal
`4cd7d11fa6c1b58026a41884a7794d2717799a545b6ae0c9f666ae1cd640f415`;
independent audit
`af303eb2c4f2d9f3ca301a82af8c22f5e75e7c9ebbb5ea1b2b76577acf3c12f8`.
Passing vendor root `ventium-state-replica-vendor-r2.bJh64t`, seal
`9149fc38b9fb7bc7e19fc03b4add7d4849209bd3e382c1e6d72fa7a1761916ae`.
The next useful hardware discriminator is simultaneous early/later PC bits
2–4 and their mux controls, because those bits differ between actual14566
and expected1457a. No CPU patch follows the low-bit mismatch alone.

#### PC bits2–4: deployment, controls and observer calibration (October6)

The nine reused observer slots now capture early PC bits2/3/4, later mux
bits2/3/4, the two mapped mux controls and FP override. Metadata is
**00cf0096**, catalogue
`b4c5a43062bcbbe1486e7f85d2f5e5ca44097fc36fe3d05e23efc06d9dc770dd`.
No FF/LUT is added; only nine observer leaf inputs and one metadata LUT INIT
change. All298156 original primitives,236980 FF-input polarities, CPU sink
paths, nine observer output routes and both constant trees are preserved.
The first native attempt rejects an incorrectly quoted Tcl expression before
opening the checkpoint; that failed fixture is retained, not a hardware run.
The separately named corrected route and bitgen close native0/pins0, with a
fully routed image and no DRC errors/critical warnings. This is diagnostic
qualification, not CPU repair or timing sign-off.

Route root `ventium-pc-word-observer-r2.KTHFxy`, closed-route seal
`2ea73c899bfc5ef08092f697bd8dc9b0007f2181038e0909440a6f9c80ac0389`;
bitgen root `ventium-pc-word-bitgen.qJXcW7`, closed-bitgen seal
`f0e7d120d7486784eacae5934f0246c9786560e94224e2d84949ca8dac187bd6`.
The native20,606,636-byte raw BIN is installed and programmed as
`/lib/firmware/ventium_fpga40_pcword_scan.bit.bin`, SHA-256
**fa2af8714ea50961f089ac04fd182d6c39c2600f67a4bdda809421d3b3b2a390**.
The closed deployment/archive consumer verifies17 source pins, all eight
unchanged production pins, actual deployment exit0 and measured held-reset
clock **39.999873027MHz**, with zero retirements. Neither the previous74d7
image nor this new image has a gameplay IPC measurement.

Three once-only cold private controls use the original CMP/JP ROM or the
existing OR/JP discriminator. There is no STEP, guest repair, production ROM/
disk change or CPU RTL modification. Each native/controller/launcher closes0;
the independent consumer checks all44 exported files, invocation identity,
actual16MiB RAM/code/mappings, coherent breakpoint architecture and the
150/338-bit scan layouts. BP stops precede any exception; CR2 and the ordinary
exception record remain zero. Raw state28, ACTIVE0, CE1, U/V lengths low3/2
and VccA are common to all three. EIP-D bit5, Vrel bits23–31 and length bit3
remain **unobserved**, never fabricated.

|Observation|CMP/JP fault|CMP/JP not taken|OR/JP taken|
|---|---|---|---|
|Case / FLAGS|2 /887|0 /2|2 /86|
|Actual primary / next PC|14562 / **14566**|14562 /14567|14562 /1457a|
|PF D/Q / mapped PC selector|1/1 /1|0/0 /0|1/1 /1|
|Early PC bits `[4:2]`|**111**|001|110|
|Later mux bits `[4:2]`|001|001|**001**|
|Final EIP-D bits `[4:2]`|001|001|**110**|
|Actual EIP-Q bits `[4:2]`|001|001|**110**|
|Mux gate14 / gate31 / FP override|1 /0 /0|1 /0 /0|1 /0 /0|

**Important correction to the localization:** the healthy taken control also
has a later-tap mismatch. Its actual destination and independently sampled
final EIP-D bits are correct, while the intermediate sampled mux retains001.
Therefore this intermediate mismatch is **not fault-specific** and does not
establish a bad Boolean mux, state-replica disagreement or the first point
where the CPU chooses the wrong PC. Early bit2 differs between the fault and
healthy taken captures, but unmatched analog sampling times prevent assigning
causality to that difference alone. The original actual14566 fault remains
real and uncorrected.

Closed capture identities:

- Fault jWIi1Z: invocation `685199ed543c49d09a094eaf4402d243`, manifest
  `b428253b61d9f90844f20e84c59e72cebf2a604fd2dd503e472f9eeb6e110035`.
- NT Hzf0Nt: invocation `2bf92995c41b4e6d8042c48491c712e5`, manifest
  `87079b80e494891d99dc53f72e3f6f68064d7f1451a1c95da673ebc7844042fd`.
- Taken iirKUH: invocation `c33decc2b5f94aa18cb2bf1774822af1`, manifest
  `09f61561914ec0aa2aaad06b88ec0a30a850c9e123e688e9b1084ae8fc2a13b2`.

Recovery root `ventium-pc-word-captures.EOTvAv`, complete round seal
`9a8aea5f402601eafedc7764fba6503bf94654bcdd9f264442ed083964f4f10c`.
After full host retrieval/audit/seal, the three closed board VHD/RAM/export
duplicates are pruned, retaining original metadata, all full host captures
and the seed. One redundant installed a533 intermediate firmware and the new
upload duplicate are also removed after recovery/hash verification. Current
fa2af871, preceding74d7, baseline53f129e9 and other retained rollback firmware
remain installed. The removed firmware is recoverable from its sealed host
bitgen output. There is no active guest or Vivado worker at this closure.

A subsequent **read-only** native query of the actually deployed checkpoint
closes0/pins0. The final independent consumer verifies605 observer cells,
all234 pre/record chains, all105 readout-graph LUT truth tables and ordered
physical inputs, plus all32 registered response lanes. Its2,100 native-LUT
readout checks cover every150-bit one-hot across all seven extension
selectors, accepted and rejected reads. This rules out an incorrect symbolic
lane mapping in that checked readout graph; it is not an analog capture proof.
The first consumer incorrectly omits the32 response FFs, the next assumes
non-inverted response reset, and another mistakes a catalogue reminder for a
numeric polarity. All failed fixtures are retained. The final consumer checks
the native inherited active-low reset source/polarity explicitly; no hardware
or checkpoint is rerun or edited to satisfy it.

The local48-case truth proof shows that each later LUT6 is exactly an identity
on its primary-PC input when gate14=1 and gate31=0, for **every value** of the
other data inputs. It requires no state-Q agreement assumption. The sampled
records violate that stable identity in fault bits3/4 and healthy taken
bits2/3/4, so a collection of correct digital bindings is not sufficient to
treat the recorded intermediate signals as one coherent settled instant.

The72 native endpoint-delay objects have exact net/to-pin identities and
units **picoseconds**. Relevant slow-corner min/max net/site delays:

|Endpoint|Bit2|Bit3|Bit4|
|---|---|---|---|
|Original EIP clock|2323/2597|2324/2603|2335/2617|
|Early observer clock|2232/2491|2232/2491|2232/2491|
|Later observer clock|2234/2496|2234/2496|2234/2496|
|Early source → observer-buffer input|1055/1544|826/1300|725/1083|
|Later source → observer-buffer input|1612/2452|1289/1949|1614/2401|
|Primary source → original mux input|153/224|750/1112|811/1201|
|Mux source → original final-D input|289/440|391/595|405/629|

The observer additionally has a LUT1 buffer before each sampling FF. These
numbers are **not** total logic delays, setup/hold margins, measured Fmax or
proof of a timing failure. They show why the distant diagnostic path cannot
be assumed to have the CPU endpoint's aperture. Readout/layout correctness
and the observed healthy-control contradiction both have to be respected.
Query root `ventium-pc-word-capture-query.HqHaOA`, complete query seal
`f6216f039559d86c4a6b694bd171833239a6a7100ebd75b9ab3a54dd40b12e90`;
final consumer hash
`237d6d6e8d5c2b2d65e348558e0ca8d9972728944fea378bdcb1b64d4389a6a7`.

**Next repair direction:** first calibrate any new intermediate probe against
the CPU's actual registered outcome on both healthy transitions; do not infer
instantaneous causality from an unqualified tap. A general, function-equivalent
local PC-commit path is worth evaluating against the native mux truth tables
and every reset/FP/exception priority before a bounded physical change. Neither
an unproved bypass nor disabling pairs, unconditional bubbles, reduced-clock
acceptance or a guest-specific patch is acceptable. CPU changes still require
the differential gates and the complete standard suite. The40MHz cold
production timedemo/movie and a current-image gameplay IPC remain **pending**.
Latest verified gameplay baseline remains **0.165996 primary/U-only IPC** on
53f129e9 at37.5MHz,127 qualified intervals spanning cycles
8,721,490,845–19,169,282,165; it predates both diagnostic candidates and is not
total U+V IPC or a whole-demo all-cycle measurement.

The subsequent conservative DATA proof establishes a possible general bypass
for **PC bits0–7 only**. Under the four actual physical control cutpoints
`gate14=1, gate31=0, FP_override=0, reset=0`, original final D equals the
primary-PC carrier for both carrier values and all other input values. A mux
`fast_condition ? primary_PC : original_D` would therefore preserve the
checked stable function: inactive conditions retain original D verbatim.
There is no state-replica equality, opcode or guest-value assumption. This
proves a conditional **Boolean identity**, not routing feasibility, analog
capture alignment, timing closure or a processor repair. No mux is applied.

The bounded source query contains only the low eight EIP-D endpoints; bits8–31
are explicitly **not proved**, not failed CPU cases. An initial structural
lookup reaches absent bit8 and stops; its empty output and traceback remain
preserved. The separately named final consumer bounds that missing scope
explicitly and closes0. Wider application requires a fresh current-native
binding/function query first. Root `ventium-pc-commit-bypass-proof.GMtr3J`,
final proof seal
`ee5db78aca821e335954e0f5d1d25889b239255d359180e6be864e3fbe523c68`;
proof output
`3d68101da84fe5d650b8d47dfa639e4827e312f257028566ccf81e402cf647d1`.

#### Full-word proof and bounded local PC candidate (October6)

A fresh **read-only** query of the actually deployed ca23d499 checkpoint
closes native0/pins0. It covers all32 original PC-D endpoints, four physical
control outputs and CODE32,291 mapped fanin cells and176 nearby slice sites.
The three-level query is bounded, not a full processor-cone proof. No CPU,
clock, routing or checkpoint is changed by this query. It runs as one worker
with a6GiB RAM/no-swap cap and450-second timeout, completing without OOM.

The first consumer recognizes only the low15 LUT6/LUT6 structures and
explicitly leaves bits15–31 unproved. The separately named second consumer
also handles the native MUXF7/MUXF8 structures. It proves the selected
identity for **all32 bits** under the same four physical cutpoints:

```
gate14=1, gate31=0, FP_override=0, reset=0:
    original_final_D[bit] == selected_primary_carrier[bit]
```

Each carrier is independently fixed to0 and1; all other physical inputs are
conservatively arbitrary. There is no assumed state-replica agreement,
opcode, PC address or guest-value condition. The native structures are15
LUT6/LUT6,12 LUT6/LUT3/MUXF7 and5 LUT6/MUXF8/MUXF7. High-bit carriers already
contain the original mode/width handling; the proof does not substitute an
unmasked arithmetic word. The proof establishes a stable Boolean identity,
**not** analog settling, timing closure, a fault cause or a processor repair.

Query/proof root `ventium-pc-commit-full-query.XqSdfq`, full closure seal
`052791a097b7d4b78aecf49163379fd90aa1facd64c10061206b95e0687adf68`;
native data
`1b0c790e8b50a6a9d267a66ad20c17db79c3af8204b093cfcf846354487c109c`;
passing consumer
`45121001fbc9ba23bdc77bb4ef7fb1a4bcd1ae737b8a813961dd55c995cbd65e`.

The vendor-primitive miter exhausts6,144 cases over all three structures:
384 selected cases and5,760 inactive cases, including reset and FP priority.
The original unprimed vendor-model fixture fails at vector0 with uninitialized
combinational outputs and is retained. The separately named corrected fixture
forces initialization transitions and passes. A second exact-representation
test also passes6,144 cases with the prospective final **LUT6** INIT
`64'hCACACACACACACACA`, not merely an abstract mux or a three-input surrogate.

The proposed physical candidate keeps every original PC FF and every original
final-LUT output/observer route. It adds32 copies of the original complete
final-D function and three local predecoded selection LUTs,35 LUTs total and
**zero FFs**. The original final LUT selects the primary carrier only under
the proved condition; otherwise it selects the copied original D verbatim.
Original reset, FP, exception and mode priorities therefore remain part of
the original function. There are no forced flags, disabled pairs, bubbles,
clock reduction, snapshots or production guest patches. CPU RTL is untouched.
The inactive physical path gains a LUT stage, so hardware corner acceptance
is still required even though the stable function is equivalent.

The bounded route contract allows only96 original LUT-input changes and204
new LUT-input connections. It requires unchanged original placements, FF
polarities, pin maps/locks, clocks, constant trees and all32 original PC output
routes; only declared input leaf branches may be removed. All other original
CPU sink paths must survive, and the independent consumer must verify the
post-router new-cell truth tables and all300 logical source bindings. The
existing EIP-D scan output pins remain the actual final-D pins. The sampled
older state mux must **not** be treated as the selected fast path when the
new predicate is active. None of these criteria certifies routed timing or
hardware execution on its own.

Three closed, non-deployed native failures are preserved:

- `ventium-pc-commit-bypass-eco.4GzXmk`: native1/pins0. Vivado rejects
  reapplying existing LOCK_PINS on an already placed LUT. No checkpoint or
  bitstream is written. The correction retains the existing complete native
  locks literally; it does not unplace cells or relax pin protection. Seal
  `a9574ca27767b8d8d3add2eeb9c89774115835a4d5af4200950c3898386bc64f`.
- `ventium-pc-commit-bypass-eco-r2.57Vs62`: native1/pins0. The selected router
  reports unreachable clone9/I4 at SLICE_X73Y223/A5 and clone15/I5 at
  SLICE_X74Y224/B6. A free LUT BEL in a partly used slice is not proof of an
  available input route. No candidate checkpoint/bitstream is written. Seal
  `def1015fa0668be57ddd9d64ed4335fe76eb571df66df58b96f405744524a581`.
- `ventium-pc-commit-bypass-eco-r3.7bUz9w`: native1/pins0. All300 selected
  connections route, and the original cell/pin/route-preservation assertions
  pass. The final physical gate nevertheless rejects two PDIL-1 errors and43
  critical routing warnings. New predicate2 at SLICE_X73Y230/A6LUT and clone16
  at SLICE_X75Y210/A6LUT conflict with inherited GLOBAL_LOGIC0 LUT
  route-through programming (`O6=1`). A cell-free BEL is not a routing-free
  resource. The rejected candidate never reaches checkpoint writing or
  bitgen; this placement defect is not evidence of the original CPU fault.
  Seal `4bfecee336ce78deba245412d05827094e74af5d44ef3c1a3ab2b0163976ed07`.

The separately named R3 plan changes only the R2-unreachable clone placements, into
B6LUT/C6LUT at SLICE_X73Y222. The current native inventory and an explicit
preflight require zero original cells and zero used site PIPs there. All
other placements, functions, connections and route protections are retained.
Plan hash
`696d4f5c0d8d7a6f35a5abe32c8d294ead9c0a99f5e9850291670daa3ffa41b4`.
The physical gate has now rejected this plan despite its route-preservation
checks; it is **not a saved or deployed repair**. The next read-only query
checks all176 inventoried nearby sites for routed owners on native site-pin
nodes, not just primitive occupancy and used site PIPs. Any new placement
must exclude inherited routing resources; the full physical gate remains
mandatory afterwards. No DRC waiver, constant-tree rewrite or original pin-map
relaxation is authorized by this investigation.

The current board remains fa2af871 at its previously measured39.999873MHz;
there is no current-image gameplay measurement. Neither the proof nor the
route attempts complete the40MHz cold production timedemo/movie or the
standard suite. Verified gameplay baseline remains0.1659957781052303 U-only
IPC, build53f129e9 at37.499869765MHz,127 qualified active intervals with gaps
spanning cycles8,721,490,845–19,169,282,165. It predates this proposed candidate.

The176-site query closes native0/pins0. Of47 originally cell-free,
unprogrammed sites, six have inherited signal owners;41 have no original
cells, used site PIPs or **query-reported signal** owners. Its first consumer
incorrectly expects `get_nets -of_objects` to enumerate physical
GLOBAL_LOGIC0 at the two DRC-rejected sites and closes1. Preserve that failed
consumer and empty output. The separately named R2 consumer explicitly bounds
the API coverage, verifies all176 original inventories and4,177 per-pin
ownership records, and closes0. The two known bad sites are excluded by
their existing cells, site PIPs and signal owners; absence of reported owners
alone must not certify constant-route freedom.

Read-only root `ventium-pc-commit-vacancy.udJybq`; closure seal
`2022faf05f77a4d54f9e57dffc0bd609172340b124a8d6a50a4a99d5cb0bb040`;
passing bounded consumer
`326a8d91ef22b2e198da945e051ad3bf6638ab1c83fcbaad4b658e423743976b`.
This query changes no checkpoint or board state.

R4 selects **all35** new LUT locations from those41 conservatively qualified
sites, instead of choosing cell-free BELs inside partly occupied slices. It
repeats the same native ownership preflight before any mutation, retains all
original protection/physical gates and passes the same6,144-case vendor
primitive miter. Root `ventium-pc-commit-bypass-eco-r4.CFPOpr`, plan hash
`c9956877c5c6a34041cf0c74c0e97e05376bf20699adf87dac9f7add62cf034e`.
The bounded worker closes native0/pins0 and its independent consumer closes0.
All300 targeted pins route successfully. Original298,156 primitive placements
and functions outside the32 declared final-PC LUT INITs are unchanged;
236,980 FF input polarities,329 hierarchy protections, original pin maps/locks,
all32 original PC-output routes and560,167 non-target route strings survive.
The reopened physical state is fully routed, with zero route errors, zero DRC
errors and zero critical warnings. This is not timing or hardware acceptance.
No CPU RTL is edited. At this route gate, the candidate is not yet deployed.

Saved R4 checkpoint
`dd1e64cd9ad2451e824a7404563ba170c3e1d6e634398c179a1094b7c0df7e63`;
route closure seal
`70641902f5a7e07da625acd23a99f101e3eb411e12d3cc0ae62ebda902776551`;
passing independent consumer
`47f4d956b7e7e6d96973a7b17a0de9ffff1c52c17439943a2ef1e88347b8db5f`.
Before bitgen, a separately bounded native pass must reopen parent/candidate
and compare the canonical POWER/GROUND routes, every node and every PIP; the
site-pin ownership query did not enumerate those physical constant trees.

#### R4 bit generation and rejected 40MHz cold execution (October6)

The separately bounded bitgen pass reopens both ca23d499 parent and dd1e64cd
candidate. Canonical POWER and GROUND route strings, every node and every PIP
match exactly: POWER70,944 nodes/57,982 PIPs; GROUND106,722 nodes/103,141 PIPs.
It also rechecks the32 changed final-PC functions, all32 complete original-D
clones and ordered inputs, three selection predicates, the actual PC-FF
drivers, existing final-D observers and nine vector taps. Observer ABI
`00cf0096` is unchanged. The physical state is fully routed with zero route
errors, DRC errors or critical warnings. Native0/pins0 and the independent
bitgen consumer0 close without OOM. This establishes physical validity and
stable-function equivalence, **not** correct hardware execution.

Bitgen root `ventium-pc-commit-bitgen.7ai680`; closure seal
`64ee8e86b098ff6fe9a819dd7c977f41ead162c5e183da1f1cd26735385b6c89`.
The native20,606,636-byte bin has the AA995566 sync word at byte80:
`5a0561fc1df1d9b53961b4a1a782c3af10e4ff22f308b4e45d2ad71f2a8b1225`.
No synthesis or global place/route is repeated during this pass.

Deploying5a0561fc on the same board boot closes loader0 and manager operating.
DDR reservation60000000–6fffffff remains excluded from Linux RAM. All eight
production pins are unchanged. Held reset measures **39.999875866980MHz**
over200,004,180 clocks/5.000120017s, with zero retirements and100 reset/freeze
guards. The deployment source audit independently checks all14 pinned inputs
and recomputes the clock arithmetic. Deploy success does not accept the core.

The cold original paired CMP/JP64 diagnostic **fails** on this candidate:

- Native unit `ventium-exception-log-0-Kan5ot.service` closes MainPID0,
  native exit0, Result success, invocation
  `bbfd544dcb53400a835152a6d96f9934`. Controller1 is a captured CPU failure,
  not a daemon crash, observation timeout or verification success.
- The old bad-PC14566 breakpoint misses (exit2). Only two cases complete;
  caller count3 and checksum9fff identify the third call.
- Primary retirement history is `00a7:14562 ->14576 ->14579`, followed by
  the exception entry. Correct parity-taken destination is1457a. This ring
  does not expose every V retirement, and its packed `lin` field is not an
  MMU linear-address oracle.
- The code bytes are unchanged.14576 executes `ADD ESP,16`;14579 is RET.
  An independent offline LDT/page-table walk locates that RET's zero stack
  word at physical001e5808. The exception record independently agrees:
  #PF14/error4, savedCS00a7/EIP0, FLAGS2, ESPe080c/SS00af, CR210000000.
  This explains the fault **after** the wrong jump, not the cause of the
  wrong destination.

There is no STEP, breakpoint on the intended paired V14565, disabled pairing,
forced flag, save-state or production-media patch. The private ROM substitutes
JP for one original JNE byte and is diagnostic-only. It is not a Quake timedemo
or standard-suite result. The candidate is **rejected**, and no production
timedemo is started on it. The changed wrong destination is not proof that the
original fault is fixed, nor evidence of a particular analog timing cause.

All41 exported files pass their recorded hashes. Archive root
`ventium-pc-commit-board.MVYK5u/exception-log-Kan5ot-export`; manifest
`6d98b4f949b53b65e72a6636a1e910a589c0d87712dcb97b177afd10d1110fcd`;
physical16MiB RAM
`b19b550907e7f635af23b48089ef97d7aa4419ce616bbfbf32dcbf9438af1d69`.
The independent failure consumer closes0, explicitly with CPU acceptance false.
Deployment/failure/cone-analysis audit seal
`42d1d8e96776e13ff3a86ea4a7cc2e2746be6f471a8b8fafebf4aaf4465e3344`.

To fit the new installed firmware on the nearly full board root, only the
already archived intermediate74d7cf7d pcvector firmware copy is removed
(20,606,636 bytes). Its exact host recovery remains under
`ventium-pc-vector-bitgen.LvID7D/native-output/`. After deployment, the duplicate
uploaded5a0561fc bin is also removed; its installed firmware and sealed host
bitgen master are retained. Original production,53f129e9,48288e83,3be5b6e4
and fa2af871 rollback firmware remain untouched.

After the separate host archive/audits pass, exact closed-run pruning removes
the42 exported duplicate files and only the original run's duplicate VHD and
physical-RAM dump. Native closure/invocation, controller1, every export hash,
seed/VHD identity and absence of open descriptors are rechecked before unlink.
All original metadata and the seed remain.44 files/101,310,815 logical bytes
are removed, reclaiming53,702,656 allocated bytes (51.2MiB) from board tmpfs.
Receipt `c48534e193baac1a923b6a9074822ba9ca4188d9c2235238b36fd3933a4789c7`
is retained under the board-audit root; recovery is the host export plus the
unchanged seed. No material board artifact is removed without that recovery.

Source follow-up uses the immutable actual-image package under
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/fpga40-srtctrl.3M3DsT/ventium`,
not the dirty current checkout. `core.sv:6105–6117` already precomputes U/V
targets independently of the branch flags; `uv_common.sv:116–131` forwards
U flags to V, and `core_fastpath.svh:835–854` selects the resolved PC. Do not
propose flag-independent target precomputation as if it were absent. The
existing three-level native query identifies the low-bit primary carrier's
LUT5/CARRY8 inputs, but leaves four upstream selection/arithmetic drivers
outside its captured cone. Their mapped functions remain unproved. Further
localization must cover those native drivers before another physical fix.

The40MHz cold production timedemo/full movie and current-image gameplay IPC
remain pending. Verified baseline is0.1659957781052303 **primary/U-only** IPC,
53f129e9 at37.499869765MHz,127 qualified intervals with gaps spanning cycles
8,721,490,845–19,169,282,165. It predates5a0561fc and is not total U+V IPC or
a whole-demo all-cycle measurement.

#### Current R4 upstream bindings, positive control and matched replay (October6)

A read-only current-dd1e64cd query closes native0/pins0 and independent
consumer0. It covers12 roots,413 mapped cells and2,959 pin records at five
mapped levels, checking11 unchanged overlapping primitives and82 original
driver bindings against the older ca23d499 query. Root
`ventium-pc-primary-fanin.0DC9yR`; native data
`23ee1a1290aa67969f95ec03494221b117d107718edad82cf81e445b7bd10cfd`;
closure seal
`17ff0238212d6089d71bc3af46c10c7bb0bcfbad96d1c3568506eb5bfd1f6f3f`.
It changes no constraints, checkpoint, route, bitstream or deployment.

Separate exhaustive checks establish only three local stable functions:

- Inner selector LUT2 `4'h2`: `I0 && !I1` (four cases).
- Low primary submux bit2 LUT5 `32'hB8BBB888`:
  `I1 ? I0 : (I3 ? I2 : I4)` (32 cases).
- V branch arm bit2 LUT6 `64'hAAAAA8080000A808`:
  `I0 && (I4 ? I5 : (I2 ? I3 : I1))` (64 cases).

The bounded carry-support analysis respects actual LUT dependencies and CARRY8
bit lanes. The physical V-decision pin is not found in the inspected taken
carry O4 cone (207 known signals/110 outside cutpoints) or not-taken carry O4
cone (211/130); it does reach the V-branch selection LUT. These bounded
absences **do not establish absence in the full graph**, arithmetic correctness,
edge alignment, analog timing or a fault cause. Unconnected native ports
remain explicitly unknown, not assumed zero. A further PC shortcut must prove
the complete32-bit function and physical conditions; these three local truth
tables are not that proof.

The diagnostic controller's normal-terminal predicate had compared low EAX
with **decimal42**. The ROM actually loads **hex0x42** before INT80 and OUT,
and pinned QEMU's expected ISA-debug-exit return is133. A separately named
controller corrects this predicate to `== 0x42`; the old sealed controller and
archives are not rewritten. This checker mistake could reject a good terminal
state, but cannot explain the earlier two-case wrong-PC/#PF capture.

The original OR/JP64 positive-control ROM is qualified with pinned QEMU pentium
(`b42b70e5`, native133) and run on the same5a0561fc candidate at measured
**39.999874995068MHz**. It differs from the CMP/JP ROM at exactly ROM7e2:
`39 ->0b`; JP14565, target1457a, caller geometry and input schedules remain.
OR additionally changes operand direction and EDI writeback, so this is not
an isolated flag-latency experiment. All64 cases and caller checks pass,
checksumd5540, with a zero26-word exception record, unchanged private code and
terminal CS8/EIPf0258/EAX42/CR2zero. Native0/controller0 close with MainPID0,
Result success, invocation `f801f1cdec7041f793a35693c4fc2506`.

OR evidence root `ventium-r4-or-control.8rT8BM`;41-file export
`exception-log-3TvooP-export`, manifest
`30a9d4627f402e418616bd9f09402eb71ee78f2200a26327d94118d6812dc360`.
The independent consumer checks source/production pins, ROM/QEMU identity,
reset scan, clock arithmetic, complete RAM scalars/record and native closure.
Closure seal
`069551808777da9f72521efa2047fe0dbdc8281707a7a703650fb13ee1a8f1c9`.
This is a private positive control, **not** a repaired CPU, production Quake
timedemo or standard-suite pass.

After this archive/audit passes, only the closed OR export duplicates and its
original duplicate VHD/RAM are pruned:44 files/101,309,308 logical bytes,
53,702,656 allocated bytes reclaimed. Original metadata and seed remain;
recovery is the complete host export plus the unchanged seed. Receipt
`c46c963239dc5d7cc20fbe58fc853745c42e2a263a44c84e6f052ef200545c18`.

The original CMP/JP64 ROM (`e6b20263`) also passes pinned QEMU pentium133.
A matched FPGA replay uses the same corrected controller, production pins,
clock and native binary, without reprogramming FPGA. Existing management
CTRL holds general guest reset, disarms the forensic comparator, clears the
old frozen rings, and retains HALT before cold init. The reset guard allows
the FPGA lifetime retirement total to persist but requires zero new
retirements; initial architectural reset and an entirely zero/invalid
retirement observer are independently checked. The current boot's2/2-cell,
256MiB, non-reusable no-map DDR reservation is rechecked outside System RAM.
Held reset measures **39.999899298432MHz** with100 guards and zero retirement
delta. No STEP, intended-V breakpoint, snapshot, forced flag, pair-disable,
clock reduction or production guest patch is used.

The corrected replay still **fails after two cases**: count2/caller3/checksum9fff,
primary `14562 ->14576 ->14579 ->CS8:EIP0`, #PF14/error4 at savedCSa7:EIP0.
Its entire16MiB physical RAM hash is identical to the original R4 failure,
`b19b550907e7f635af23b48089ef97d7aa4419ce616bbfbf32dcbf9438af1d69`.
The offline descriptor/page-table walk again derives RET's zero physical
stack word001e5808. Native0/controller1 close, invocation
`dac08d59e0984ae8a3cc685d064cf9bd`; all41 capture hashes,15 source pins,
before/after production checks and the independent failure consumer pass.

Matched replay root `ventium-r4-or-control.8rT8BM/cmp-repeat`;41-file export
`exception-log-h0y3ot-export`, manifest
`0b0ae5d324e629da9f7e84cf0675810735e4946e7ca41e6aa3d533396db8c5c8`;
closure seal
`60fe7b27d11341e3f9d82509dca5dc7f08858e326cd913aba209aac6a41248d0`.
This establishes reproducibility, not acceptance. In particular14576 is a
valid normal epilogue instruction on other cases: an unqualified breakpoint
there would first stop good execution. Any future parked capture must
qualify the immediately preceding primary retirement rather than treat
every14576 stop as the wrong branch.

The40MHz production timedemo/full movie and candidate gameplay IPC remain
pending. Verified gameplay baseline remains0.1659957781052303 U-only IPC,
53f129e9 at37.499869765MHz,127 qualified intervals with gaps spanning cycles
8,721,490,845–19,169,282,165; it predates5a0561fc.

#### Parked wrong-PC capture and corrected taken-V proposal (October6)

The parked capture is now independently audited and sealed, at
`ventium-r4-or-control.8rT8BM/cmp-boundary`. BP14576 first stops two legitimate
normal epilogues whose preceding primary is14575. Each is crossed with one
step of **ADD ESP,16**, exactly one retirement, then BP14576 is rearmed. The
third stop has preceding primary14562 and wrong next PC14576, before that bad
epilogue executes. Neither CMP nor Jcc is stepped. This is **intrusive history**,
not an uninterrupted-run replacement or CPU acceptance.

Measured clock is39.99989777851931MHz. The coherent architectural scan records
CSa7/EIP14576/FLAGS887/CR2zero/CR37e000/ESPe07f8, two completed cases,
caller3/checksum9fff and an entirely zero exception record. The linked code
is unchanged. The native/controller exits are0/0; result is
`CAPTURED_INTRUSIVE_CMP_WRONG_PC`, invocation
`b865699a175b454caa01ad7bb5e73587`, not a successful workload.

All67 export files pass the independent consumer. Export manifest:
`c99ff93efe9e3df9d09871042b73c0cde82cce22b272224859faf99c6947e372`.
Complete103-file host closure seal:
`5cb0a5fe9cb9885b6c4208ab5e287f36c2e4185041310cf51ada9ee9b7bd7260`.
The preserved150-bit observer decodes Ulen3/Vlen2/CC10/Vrel-low23=13 and
PF_D/Q1. Its retained owner is14558 and all eight current active copies are0.
These sampled combinational terms are **not a coherent settled-edge proof**:
length bit3, Vrel high bits and EIP_D bit5 are unavailable. In particular,
14558+3+2+13hex is14570, **not14576**; an old-owner arithmetic explanation
must not be asserted from this sample.

A subsequent full-word proof exposed a scope mistake in the first direct-word
proposal: carry chain `eip_reg[7]_i_28` is **fall-through/redir_tgt2**, with the
late V decision0. Its valid stable-function proof does not address this
taken-JP failure. That proposal is rejected for this purpose, not deployed.

The actual taken word is the connected four-CARRY8 chain
`ic_line_b_reg_0_i_18 ->ic_line_b_reg_0_i_13 ->ic_line_b_reg_0_i_949
->ic_line_b_reg_0_i_940`, all under the core's `u_icache`. Native CI/CO and
all32 output-net identities explicitly match `v_tgt_raw[31:0]`.
Query `ventium-vtaken-word-query.HAaDyj`, native data hash
`85992f4aa9a2226a9416cf60fee1677d4ff88c270d3a483602efbce6edfea67b`,
closes native0/pins0 and checks all32 final-PC/FF bindings.

An initial taken-word proof passes low16 but rejects high16 without the
**effective V operand-width** guard. Adding native
`u_icache/eflags[7]_i_20/O ==0` selects the actual live/retained w16 value;
replica agreement is never assumed. Minimization safely removes all four
code-size-Q cut conditions. The resulting10 physical conditions cover reset,
outer/state/inner selects, FP override, U branch, V admission, V taken and
effective Vw16. Ineligible, reset, FP-priority and w16 cases retain the complete
original-D copies; there is no opcode, PC or guest-specific condition.

The independent literal-minterm encoder closes both the64-bit conditional
original/primary-to-taken miter and the unrestricted32-bit proposed-mux miter,
with satisfiable active/inactive witnesses. Proof hash:
`774b6e5fc8a0db4728491f1022da90090a156405beccb4e1af4244a4b48b7598`.
Vendor primitive models pass196,608 checks, including both early predecodes,
three reused local qualifiers and payload selection. These prove only the
bounded captured stable functions: opaque carry/cutpoint values remain
independent. They do **not** prove arithmetic, full-cone timing, the fault cause,
a repaired processor, or timedemo acceptance.

The proposed physical change adds **two LUTs/zero FFs**, updates three existing
qualifier INITs and41 original inputs, and routes exactly50 inputs including
nine new ones. All32 existing PC output/FF/observer routes must remain literal;
all original placements, pin maps/locks, FF input polarities, clocks, constants,
undeclared routes and retained source paths remain mandatory guards.
Plan hash `14f52de0c95b2fdf5c4d271e93e7afbf3e1679f225fd87ffc376b4fb798f229f`.

#### Bounded implementation attempts and exact cleanup (October6)

The first taken-word attempt, `ventium-vtaken-direct-eco.lB9cn1`, stops before
any selected unroute or connection at scoped5,420,883,968bytes. The corrected
ownership watcher, not the original empty watcher, establishes invocation
`8419148ba40c477eaeac100cc274d99f`; all observed max/OOM/kill events are0.
Native143/pins0; no candidate checkpoint or bitstream. Its unqualified
589,279-row full-alias route export duplicates1,353,245,691bytes.

R2 (`ventium-vtaken-direct-eco-r2.OlJ7hS`) streams primitive/FF snapshots and
stores canonical physical routes once while retaining every alias identity.
It closes native1/watch0/pins0 before routing because the new canonical helper
incorrectly uses a net as `-of_objects`. Peak scoped4,531,027,968bytes; no OOM.
The [2025.2 get_nets contract](https://docs.amd.com/r/2025.2-English/ug835-vivado-tcl-commands/get_nets)
uses a net pattern for this operation, rather than a net-to-net object relation.
A separately closed native query (`ventium-net-group-api.7OHpnM`) validates135
aliases,115 bracketed names and135 independent leaf-pin agreements. Native,
watcher, pins and consumer all close0; query hash
`d103048a3b5e287366215481c50d0ea46ad8a441260231da7b4a1f351d0eca50`.
This is a read-only API check, not proof of every design alias or hardware.

R3 (`ventium-vtaken-direct-eco-r3.MoyAuG`) validates the corrected API over all
589,279 original aliases and exports416,931 canonical physical routes.
Route data is218,095,063bytes; the full alias map is148,781,011bytes. The native
preflight covers298,191 primitives,236,980 FF input polarities,329 hierarchies,
74 source groups and all32 output routes. The41-pin selected trim and50 logical
connections execute only in the private in-memory candidate. The watcher then
stops router initialization at5,375,492,096bytes, with zero OOM/max/kill events.
Native143/watch3/pins0; no completed route, physical acceptance, checkpoint or
bitstream. The original routed master and installed5a0561fc image are unchanged.

R4 (`ventium-vtaken-direct-eco-r4.4ntPKn`) is prepared, **not yet launched**.
It releases dispensable Tcl cell/trim indices before routing and reread export
page cache before final reports. No correctness guard is removed. Its reviewed
envelope is one worker,7GiB hard limit,6GiB early stop, zero swap,2GiB live host
reserve,9GiB minimum available RAM and a570-second process cap. No unrelated
application, including Chrome, is killed to admit it.

After rechecking the complete103-file host seal and closed board invocation,
only the67-file parked export, its manifest and original duplicate VHD/RAM are
pruned:70 files,54,546,432 allocated bytes reclaimed. Metadata, firmware and
the unchanged recovery seed remain. Receipt
`d23129a8f6bbe163e22988d43ba79800f9bf8d5e884da4fef7f1836a3923ef18`.
The first stopped run's single unqualified route export is also pruned after
hash/size/inode/no-open/native-closure checks:1,353,252,864 allocated bytes.
Its SHA is `744f8d236f99c1d94e1dda1d5b06e7625b892b44821c9c3d45278869f233ae60`;
receipt `b084c95e3e24168615c3cdb66da1785776d1b30576bd5c0a2c88d6ec75ec0de9`.
Sources and stop evidence remain; that generated export is reproducible from
the unchanged dd1e64cd routed master. Cleanup receipts/sources are preserved in
`ventium-net-group-api.7OHpnM`.

No CPU RTL edit, synthesis, global placement/routing, new bitstream or deployment
occurs in these attempts.40MHz cold production timedemo/full movie remain
pending. Candidate5a0561fc gameplay IPC is unmeasured. The labelled baseline
remains0.1659957781052303 **U-only**,53f129e9 at37.499869765MHz,127 intervals
with gaps spanning cycles8,721,490,845–19,169,282,165; it predates this candidate.

#### All-root physical preservation audit and launch fences (October7 UTC)

The independent R3 snapshot audit checks **1,541,381 rows** across the four
closed primitive/FF/alias/physical-route streams. Hashes, record framing,
unique identities and all canonical alias groups agree. It also exposes a
verifier assumption: there are **471 logical constant roots**,243 GROUND
and228 POWER, not one logical root per type. The failed singleton-root audit
and corrected audit are both retained. Corrected audit hash:
`a2b5702ebbc09569b017eecfb238dbbf951ceb42be993187fc1d70b7d8a70559`.
This does not turn the stopped R3 implementation into a passing route.

A separate **read-only native query** on the immutable dd1e64cd master now
checks every one of those471 roots. Each root's literal ROUTE, complete
sorted node set and complete sorted PIP set agree with its type's physical
pool. POWER has70,944 nodes/57,982 PIPs; GROUND has106,722 nodes/103,141 PIPs.
Two raw full-geometry records are retained only after establishing that
sharing for **all** logical roots; distinct geometry would reject the query.

Run `ventium-constant-root-pool.kCKGiZ` closes native0/watch0/pins0 and the
independent consumer0. Scoped peak is3,946,024,960bytes (**3.675GiB**), with
all observed max/OOM/kill events0. The envelope is4.75GiB hard/3.75GiB early,
zero swap,2GiB live host reserve and6.75GiB admission, with one worker and
570-second process cap. No design mutation, checkpoint, bitstream or guest
release occurs. Native query hash:
`0a914bf712e85960b3d3b5c67e163d4a4e1cff5122aa86934b898a33f227362c`;
full geometry hash:
`73a92518fe44f6a26f5269a298dbce25101ee124a1323eb1bd9bb136cd33a6b9`;
consumer hash:
`d09d8c103badfc2fd5544c6f34f7a88cb9cf4dff82cca25f94cdd7728b6c96de`;
complete19-file read-only closure:
`1fa32edd831a6a7a2ff7a943467e99f49e6d926825878864fb0ed7958a5534e0`.

The **unlaunched** R4 local route now requires this closed native evidence,
rechecks its entire seal and independently reruns its consumer before launch.
It counts all589,279 original aliases/416,931 canonical groups and228/243
constant roots; every original constant root must retain its literal route.
Both complete raw physical pools are additionally checked after routing.
No placement, FF, pin-map, output-route, source-path, clock or DRC guard is
removed. Regenerated R4 input-manifest hash:
`e92cb7ee831b8fd5c2b3c3ef789f54e4a3cb7d0801159027a2dac80bbc01d703`.
Stale unlaunched manifest versions remain labelled and retained, not reused.

`ventium-vtaken-bitgen.pkwfo6` prepares a **single-checkpoint** final native
gate instead of opening two full designs. Before bitgen it freshly rechecks
all471 roots' ROUTE/nodes/PIPs, all32 final-PC and original-D-clone bindings,
the three8080 predicates, both early predecodes, nine vector taps, observer
metadata,40MHz clock configuration, complete routing and unwaived DRC.
It frees dispensable Tcl indices before reports/bitgen and uses the same
7GiB hard/6GiB early/9GiB admission envelope as R4. Its watcher must identify
its actual `bitgen_taken.tcl` invocation. Native raw BIN byte order and every
input/output hash are independently consumed before any possible deployment.

These bitgen sources pass shell/Python syntax and Tcl framing checks **only**;
they are not yet run or vendor-qualified. Static-source-list hash:
`ba80a9886210a5b0c959099ccc618f2b15c871cfc8fbe6967cc1fb7498c895fc`.
The runnable input manifest deliberately does not exist yet: it must include
the still-missing accepted R4 checkpoint, route closure and consumer result.
The launcher refuses absent evidence; the master query cannot substitute for
fresh candidate checks, physical qualification, silicon tests or timedemo.

At this checkpoint no Vivado process or guest run is active; available host
RAM is about8.2GiB, below the9GiB routing admission threshold. No unrelated
application is closed and no guard is weakened to start a run. The installed
rejected5a0561fc image remains unchanged. Original40MHz cold production
timedemo and full movie remain pending. Candidate gameplay IPC is unmeasured;
the labelled0.1659957781052303 U-only baseline is53f129e9 at37.499869765MHz,
127 intervals with gaps spanning cycles8,721,490,845–19,169,282,165.

#### Installed router-cache API: preserved master, no pre-route saving (October7 UTC)

The [2025.2 route_design contract](https://docs.amd.com/r/2025.2-English/ug835-vivado-tcl-commands/route_design)
documents `-release_memory` as releasing retained router data without running
routing passes. A bounded read-only native query on the unchanged dd1e64cd
master verifies that exact installed API instead of guessing a memory knob.
`ventium-router-memory-release.JlM2B1` closes native0/watch0/pins0/consumer0.
All416,931 original canonical routes,471 logical constant-root routes,
both full physical constant pools,298,191 tracked primitive records,
236,980 FF input polarities and original clock periods remain literal.
No route pass, unroute, function/placement/constraint edit, new checkpoint,
bitstream, deployment or guest execution occurs.

The measured pre-routing scope is4,239,822,848bytes before the call and
4,240,056,320bytes afterward: **no measured saving**, an increase of228KiB.
Peak scoped memory is4,430,077,952bytes with all observed max/OOM/kill events0.
The query's5.5GiB hard/4.5GiB early limits retain the1GiB cushion, zero swap,
2GiB live host reserve and7.5GiB admission; the process cap is390seconds.
This measurement does **not** profile an active interactive router or justify
reducing the candidate routing envelope.

Native query hash:
`1f01c3e1bec49e38f9351ce5e34abde54f1928f0943c29b40413a934aa8bf61e`;
independent consumer hash:
`3fc97ff2370e62e32215a5e8ef30be35eb15493f52d2c83ac16818988831bfdd`;
complete17-file read-only closure:
`1e3a75a6a156d8b6f51c42eed817c67deaef52c12f27a63b9c98033796d56a89`.

The still-unlaunched R4 flow now frees router caches **after** successful
selected routing and **before** every post-route preservation/physical gate.
The independent consumer requires that ordering and native cache-call success.
All existing route/function/placement/polarity/constant/output/DRC guards stay
mandatory; no saving is presumed or claimed on the new candidate. The runner
pins and rechecks the closed API query before starting. Current R4 manifest:
`63d19ce2f63be68b4b6f8e2920cb3273a56763915218e1a19cbe0efb08ac6a4f`;
the earlier e92cb7ee manifest is retained as an unlaunched historical version.

The route still needs9GiB available RAM; the host has about8.1GiB and no
remaining Vivado process. The installed5a0561fc image is unchanged.40MHz
production timedemo/full movie remain pending. Gameplay IPC is unmeasured for
the candidate; the baseline remains0.1659957781052303 U-only on53f129e9 at
37.499869765MHz,127 intervals spanning cycles8,721,490,845–19,169,282,165 with gaps.

#### Directed-path feasibility and rejected manual attempt (October7 UTC)

A read-only installed-2025.2 query explores an alternative to allocating the
interactive router. `ventium-directed-route-query.C8t6kz` records all50
planned physical input endpoints, but exits native1/watch0/pins0 because its
single-tile assumption is false: a routing node spans multiple tiles. It
does not reach path search and creates no candidate. Its partial evidence
is retained; this is not a routing or correctness pass.

The corrected `ventium-directed-route-query-r2.3j8aQ0` closes
native0/watch0/pins0/consumer0. It obtains all41 original and9 proposed input
BEL/site/node endpoints, preserves77 queried net routes and original clocks,
and finds an eight-node conflict-free RESET-source branch to the proposed
SLICE_X72Y221/A1 input. No overlap/ignore-routing option is used; no returned
path is assigned, and no checkpoint, bitstream or board change occurs.
Physical BEL queries expose site entries for all50 inputs; this does not
prove that a future placed output's site programming has been completed.

Peak scoped memory is4,343,541,760bytes. The search itself measures
4,333,977,600bytes before and4,333,490,176bytes after. This is one path search,
**not** the full candidate's routing-memory requirement. Query hash:
`0615780447ac431f2f5adb0d865ee9e8573e73383a6b489c0c112d41a57bfe9f`;
consumer hash:
`6dfd0e2854dbeb3e49ef21965afeb4f7f248177aa2c1e219ff727adda40fcbc9`;
complete16-file closure:
`b849d6b6cf5494ad8b278ac808bcc5cf2e0c87f02bee2ba243dbaa15fbf6d94e`.
Its consumer handles native Tcl records containing multiline help text;
fixtures test the actual parser, including rejection of truncated records.

`ventium-vtaken-manual-eco-r5.CqN0O7` tests a directed-tree variant of the
same14f52de0 Boolean-equivalent plan, retaining every R4 preservation and
physical gate. Fifteen route-tree microtests cover explicit singleton branch
braces, retained branches, cycles, reconvergence, disconnected components,
duplicate edges/nodes, old-tree crossings and the500-node bound. The variant
uses5.75GiB hard/4.75GiB early/7.75GiB admission, still with a1GiB cushion,
2GiB live host reserve, zero swap, one worker and the570-second process cap.
Its input manifest is
`56a83d9ce407c04c1019a48b655b9b1d2c964edc9fc410f0649d505a0e7fe12a`.

That attempt **fails** native1/watch0/pins0 before its first directed branch:
the placed new O6 output does not expose the expected route-associated site
connection. Peak scoped memory is5,094,227,968bytes, only about5.8MiB below
the early-stop threshold; all observed max/OOM/kill events remain0. It does
not establish that the full variant fits that envelope. All four complete
pre-mutation snapshot hashes equal the already-audited R3 originals, but the
private input reconnections are not qualified. No checkpoint, bitstream or
deployment occurs; the failed sources/results are preserved.

After this closes, actual host RAM rises to9.85GiB available. The original
taken-V R4 local-router flow is now admitted and launches with unchanged
63d19ce2 input pins and its7GiB hard/6GiB early/9GiB admission envelope.
It is a new active attempt, **not yet a pass**. The rejected5a0561fc board
image remains unchanged; original40MHz cold production timedemo/full movie
remain pending. Gameplay IPC remains unmeasured for the candidate. The
baseline is0.1659957781052303 U-only on53f129e9 at37.499869765MHz,127 intervals
with gaps spanning cycles8,721,490,845–19,169,282,165, predating this candidate.

#### R4 route succeeds; preservation audit hits deadline (October7 UTC)

The R4 selected router completes successfully in51seconds, followed by the
cache-only release in6seconds. The attempt nevertheless **fails**
native1/watch0/pins0: its540-second Tcl deadline expires during the complete
physical-route comparison, after the original primitive, FF-polarity,
hierarchy, physical-pin-map, source-fanout/resource and alias checks. It has
not completed the remaining constant-pool, output, full-route and unwaived
DRC gates, and writes **no checkpoint or bitstream**. Its invocation is
`5dce5c75b7f14fe4a5a73c057b497c72`; peak scoped memory is6,193,364,992bytes,
with all observed max/OOM/kill events0. These results do not qualify R4 for
deployment. The board remains on the rejected5a0561fc image.

The fresh R6 attempt, `ventium-vtaken-direct-eco-r6.KaIW5N`, changes query
execution only: native unique-root membership avoids redundant scalar
canonical queries for416,931 actual roots; all172,348 non-root aliases still
use the independently qualified scalar API. Canonical collections are never
zipped to aliases. Primitive fields and nonconstant route properties use
batches of at most256objects; every original record, alias identity,
literal route, FF input polarity, pin map, source resource, output route,
clock and physical gate remains mandatory. Constant routes are still
queried separately for every logical root to avoid vectorizing enormous
replicated constant-tree strings. Both full physical pools remain checked.

Eighteen focused helper tests pass. Before mutation, all four native baseline
exports must now also match the already independently audited R3 scalar
hashes exactly; a query-order or representation discrepancy rejects the run.
The7GiB hard/6GiB early/9GiB admission envelope,1GiB cushion,2GiB live host
reserve, zero swap, single worker and540/570-second deadlines are unchanged.
R6 launches with input manifest
`e7c2122f5f862c51466aaf862c6e72287f58837ab3b486f1795dd251558a1393`.
This is an active attempt, not a preservation, silicon or timedemo pass.
No RTL, production ROM or disk-media change occurs.

40MHz cold production timedemo/full movie remain pending. Candidate gameplay
IPC is unmeasured; the labelled prior baseline is0.1659957781052303 U-only
on53f129e9 at37.499869765MHz,127 intervals with gaps spanning
cycles8,721,490,845–19,169,282,165, predating the candidate.

R6 closes native1/watch0/pins0 **before mutation**: one batch contains
179 CARRY8s,75 FDREs, one MUXF7 and one LUT3. The single LUT's `LOCK_PINS`
query returns a scalar list-valued property, not a one-element outer list;
the strict cardinality guard catches this distinction after99,328 primitive
rows. No candidate checkpoint is written. Peak scope is4,174,360,576bytes,
all observed max/OOM/kill events0. The installed native result, rather than
the mock's earlier contract assumption, determines the correction.

Fresh R7 (`ventium-vtaken-direct-eco-r7.glSYan`) wraps singleton property
values explicitly; multi-object queries still require exact cardinality.
Twenty-two focused tests now include the native failing column geometry,
singleton list-valued pin locks, branched routes and empty routes. Every
baseline hash and preservation/physical/resource/deadline guard is retained.
R7 launches with manifest
`1a0a87f0d55d3cba7e97c0219b2b216df7c80c8a9f19009bebc2821e157499e1`
and invocation `7b36529f57a44c138d636cec857fb6a3`. This remains an active
attempt, not a route, hardware or timedemo acceptance.

#### R7 closed physical/stable-function pass; final bitgen starts (October7 UTC)

R7 completes **native0/watch0/pins0/consumer0** inside the unchanged bounded
envelope. All four independently audited original export hashes match before
mutation. Post-route comparison preserves298,191 original primitive records,
236,980 FF input polarities,329 hierarchical protection records, all original
physical pin maps/locks and589,279 alias identities. All416,931 original
physical groups are covered:416,386 non-target route strings remain literal,
74 declared source groups retain their protected resources and exact planned
fanout, and all471 original constant roots retain literal routes. Both full
physical constant pools,32 original PC-output/FF/observer routes and original
clock periods pass. The fresh canonical inventory contains416,933 roots;
post-route scalar canonical checks cover172,165 non-source/non-root aliases.

The native final report is fully routed, with zero route errors, unwaived DRC
errors or critical warnings. Peak scoped memory is6,088,130,560bytes; all
observed max/OOM/kill events remain0. No deadline/resource rule is relaxed.
The saved checkpoint is
`native-output/taken_candidate_UNQUALIFIED.dcp`, SHA-256
`56076f90e2ffdbfc4fdb78e7a9839be7f5e2c3b48c622bbc2341cafd119b7f9d`.
Independent consumer SHA-256:
`099a0c63e33e9efdfdc4df687706dc8af66d840d6529d9a18a2e2d9e103de35f`;
complete34-file closed-route seal:
`d997823a94cff0e49ab58f0e8c9f7b906cd6f76a56b2425868e42265575800b5`.

The separate `ventium-vtaken-bitgen-r7.d3qYB2` flow rechecks that sealed
producer and independently recomputes its consumer, then reopens only the
accepted checkpoint. It requires a fresh check of **every** original logical
constant root's complete route/nodes/PIPs, all32 actual taken-word muxes,
three predicates, two predecodes, inherited observer ABI/taps,40MHz clock
constraints and unwaived full physical checks before native bit generation.
It performs no synthesis, placement, routing, clock-constraint or function
change. Input manifest:
`a94f186991d8f02401619ea8243e6e36aabcbdce7c992fedb5ddc92bd741b057`.
Bitgen is launched, **not yet qualified or deployed**. Stable Boolean
equivalence and valid physical routing do not establish timing, a repaired
silicon fault or production Quake completion. Candidate gameplay IPC remains
unmeasured; the labelled baseline remains0.1659957781052303 U-only on53f129e9
at37.499869765MHz,127 intervals with gaps spanning
cycles8,721,490,845–19,169,282,165, predating the candidate.

#### R7 bitgen complete; deployed 40 MHz diagnostic still fails (October 7 UTC)

The final R7 bitgen closes **native0/watch0/pins0/consumer0**. All 471 logical
constant roots pass fresh complete route/node/PIP checks, and the reopened
32-bit PC muxes, predicates, predecodes, observer taps/ABI, clock constraints
and unwaived full route/DRC checks pass. Scoped peak is 5,416,284,160 bytes;
all observed max/OOM/kill events are zero. No additional function or routing
edit occurs. The 20,606,636-byte native raw BIN is
`886e8608a977947af4ac2d70380c11678bd13c8f8494e65c6fa38e9c66f41f4f`;
consumer hash `be3d7e2aa6637ae5a1ae6f1b5b9c28e7d07d20dcd56d025d482ed9df5af4a997`;
complete 26-file bitgen closure
`8404a43d70c5745c80e9fc505879018a52d4479a0cbe74eb3715553e7e3c5e3e`.

Deployment evidence is in `ventium-vtaken-board-r7.CBfgZM/board-deploy`.
The board's boot identity, native two-cell address/size encoding,
non-reusable `no-map` reservation 60000000–6fffffff and exclusion from Linux
System RAM pass. Programming exits zero; the installed firmware hash matches
the qualified BIN and the manager reports `operating`. A held-reset interval
measures **39.999877515 MHz**, with zero retirements and 100 reset/freeze guards.
Production source pins pass before and after deployment.

Cleanup removes three closed, seed-identical diagnostic `run.vhd` copies
(eVX6lv, orsAkx, mvnVlx), reclaiming 58,097,664 allocated bytes. The rejected
`ventium_fpga40_pccommit_candidate.bit.bin` firmware copy is also removed;
its verified host copy remains in `ventium-pc-commit-bitgen.7ai680`.
Receipts identify exact targets and preserved recovery sources.

The original cold paired CMP/JP64 diagnostic **fails** on this image.
`exception-log-GHXp5j-export` contains 44 hash-verified files; its manifest is
`69ba0ab7e2fb238a6e569a50152cb8f26ee7702e457200eb973ca67b206e9967`.
Native invocation `e11d9df2116249d1899f283f18164021` closes normally with exit
zero, while the controller exits one. One case completes; caller count is two
and checksum is `0x6aaa`. The failure breakpoint catches CS:a7 EIP:14566,
FLAGS:2 and EDI:0 after primary retirement 14562. No fault record has yet
been published. The code bytes are unchanged.

The observer reports U/V length low bits 3/2 and JP condition code 10.
Its partially known previous-edge EIP-D is 1455a with mask ffffffdf;
the selector is zero, EIP CE is one and observed PF is zero. These samples
do not prove ownership or alignment with the failing commit edge. In
particular, they do not establish a one-byte V instruction or the cause of
the bad PC. This is an earlier failure than the prior image's third-case
taken-branch failure, and does not establish a silicon repair.

The next matched control uses fresh scratch `ventium-vtaken-no-bp.1qBob9`,
reloads the identical BIN and uses the pinned probe's `run` operation, which
clears BP_EN and HALT_REQ. It checks that the breakpoint stays disabled while
watching the unchanged 64-case diagnostic, then captures architecture, RAM
and observer evidence. The prior diagnostic's seed-identical disk copy is
removed only after native closure and verification of its complete archive;
the original seed and host/board evidence remain. The fresh held-reset clock
measurement is 39.999875019 MHz.

The control closes **native0/controller1** and reproduces the failure with
breakpoints disabled. One case completes, caller count is two and checksum
is 0x6aaa. The raw physical-RAM record reports #PF14/error4 at CS:a7/EIP14566,
saved FLAGS:2 and CR2:493c6488. The private code is unchanged. The pinned
probe's resume exits zero; breakpoint-disabled status is checked before
release, throughout the result poll and at the final halt. The final observer
sample belongs to the exception logger, not to the bad commit edge.

All 42 files in `exception-log-TICi2s-export` pass their recorded hashes.
Native invocation is `f5ac2de765124ceab97ff24a255d0583`; manifest SHA-256:
`14a7bb2e2371fe5c46005cb7cb54ce3f45c5b474d9b6c0f0a1e29965214a9b06`.
RAM SHA-256:
`ea6dc9ff7e17fa2de9b0b50397a55ed1371db682331728c2a0aeccde8f4290fd`.
The independent `audit_failure.py` recomputes clock arithmetic, checks native
closure, source/ROM identity, breakpoint status and fault/scalars directly
from physical RAM. Its result hash is
`c622a28869deacf1648a342a3831db3f3060188a9ada7a6b96a10d9d20c09e33`.
The audit passes with CPU acceptance false. The execution breakpoint is not
required for this failure.

#### Combine the two general PC shortcuts without losing the earlier path

Inspection identifies a structural limitation of R7: its final mux selects
`taken ? raw_target : original_D_clone`, replacing R4's
`fast ? selected_primary : original_D_clone`. Therefore non-taken fast
instructions lose R4's shorter path and pass through the old-D clone again.
This explains which path was changed; it does not by itself prove the
electrical cause of the second-case failure.

The next candidate preserves both paths in the original final LUT:

```
taken ? raw_target : (fast ? selected_primary : original_D_clone)
```

`ventium-pc-combined-proof.f1HQc9` encodes the actual mapped native cone and
proves the complete 32-bit function equivalent to the R4 parent for arbitrary
unqueried cutpoints. All three selection cases are satisfiable. The miter
returns `sat/unsat/sat/sat/sat`; proof result SHA-256:
`641bed7d0607064ed146c6807b2d36efab0cca305b902b7b483c3e776814ba56`.
The exact AMD LUT primitive fixture passes 196,608 comparisons: 192 taken,
12,096 other-fast and 184,320 original-path cases. It tests reset/FP/mode
eligibility and all payload combinations. This is stable-function evidence,
not arithmetic, timing or hardware acceptance.
Proof and vendor-fixture closure seal:
`eca19518d9419322f8d2b6fc2f756e0720a02009681f49e802f8260fc7f9eed9`.

The local implementation plan `ventium-pc-combined-eco.M47s1n` starts from
the sealed dd1e64cd R4 checkpoint, adds five LUTs and no FFs, and keeps the
three original fast predicates and final I0/I1/I2 inputs intact. Final LUT6
INIT becomes `FF00CACAFF00CACA`; only I3/I4 gain raw-target/taken-select
inputs. There are 64 original input changes and 18 new input connections.
Plan SHA-256:
`db188393475609d1c8b20f24b1edc04b86ae12b9b95745bdb73cf3fa89aae9ab`.
The real Tcl plan parser passes its 82-pin scope check; all 22 query helper
tests pass. Original placement, FF polarity, pin maps/locks, PC output routes,
all other routes, constant pools, physical DRC and resource guards remain
mandatory. No native implementation has launched yet; the host currently
has less than the unchanged 9 GiB admission threshold.
The bounded admission watcher is queued with source manifest
`8a2b24d6c3b95ec5322839c3c164c5324cfee4592d6666375247f57045aa6301`.
It requires two consecutive memory admissions and then hands off to the
unchanged single-Vivado wrapper, with a 7 GiB hard/6 GiB early limit, zero
swap and the 540/570-second native/process deadlines. It times out after
600 seconds if memory never becomes available, without launching Vivado.

Closed no-breakpoint evidence seal:
`13f12a04d7e166af7976f21f96dfd82a5b4886b63f94f92495991ae5176a849e`.
To prepare room for the next deployment, five exact closed duplicates are
removed from board tmpfs: both board copies of the GHXp5j and TICi2s RAM
dumps, plus TICi2s's seed-identical disk. Complete host captures and the
recovery seed remain; hashes, native invocation closure and absence of open
descriptors are checked before deletion. This reclaims 86,474,752 allocated
bytes and leaves 136 MiB free. Cleanup seal:
`16e3f18c52c06aaad032087587bc161cae376633fc2d522202f63c8fa233b3b9`.
The final-audit/bitgen adapter is prepared separately in
`ventium-pc-combined-bitgen.yYhium`; its actual plan-loading block passes
32-bit/five-new-LUT checks. It cannot launch until the new route producer and
independent consumer close successfully.

The admission watcher subsequently closes with exit 75 after its 600-second
wait, reporting `memory_admission_timeout` and `launched:false`. Its last
sample is 9,028,972,544 available bytes against the unchanged 9,663,676,416-byte
requirement. This is a resource-admission timeout, not a native route failure.
There is no `launch.once`, native output or new combined checkpoint/bitstream.
The pinned attempt remains ready for launch after RAM admission succeeds.

#### Smaller memory profile and corrected count guard (October 7 UTC)

A further review catches a stale post-route `original_count + 2` assertion
in the unlaunched combined-flow adapter, whose plan correctly declares five
new LUTs. Fresh `ventium-pc-combined-eco-r2.sjsI7c` uses the actual declared
created-cell count. A test executes that exact native guard with five new
cells and checks that a missing cell is rejected. No faulty checkpoint was
produced by the earlier adapter.

The closed R7 resource log places its maximum at the last sample: about
5,751 MB anonymous memory plus 309 MB file cache and 23 MB kernel memory.
The new attempt adds a narrowly allowed, streaming SHA-256/cache-release
helper for the task's checkpoint, plan, constant-geometry and proof files.
It verifies content and file identity while issuing advisory per-file cache
eviction; it does not drop global caches or touch unrelated applications.
Independent known hashes for all four existing inputs agree. Test-result
SHA-256: `39f98d589f955a0effc2949064082e430acd0912dee3fd27f74d4b5b64de2d00`.
Memory savings remain unmeasured because this attempt never enters Vivado.

The smaller profile lowers the hard cap to 6.5 GiB and the early stop to
5.5 GiB. Admission correspondingly requires 8.5 GiB. The existing 1 GiB
early-stop margin, 2 GiB live host reserve, zero swap, single worker and
540/570-second deadlines are preserved. All functional, complete-route,
constant-pool, original-primitive and physical DRC checks remain mandatory.
The 82-pin/five-LUT plan and its 32-bit function are unchanged; the formal
proof and vendor fixture are recomputed successfully before launch.

Input manifest:
`07f2075a8af12ffa7ab174635af5b2d6a28ac8bccc98c26f7f98c3eae10ed9d8`.
The watcher observes two samples just over 8.5 GiB, but available memory
falls again before the unmodified build-scope wrapper's own admission check.
The wrapper refuses with exit 125; the watcher closes with zero samples and
the input-pin check exits zero. No vendor process, native output, checkpoint
or bitstream is produced. This is another resource-admission failure, not a
CPU, routing or OOM result. Closed admission evidence:
`aa51c8956b77b17e68d25d1d2111e6a424532d33e56bc0b21ac8f25045c94c84`.

The original 9 GiB attempt and this closed refusal remain preserved. After
RAM becomes available, create a fresh attempt from the corrected R2 sources;
do not reuse its `launch.once` directory. The bitgen adapter now targets R2
and the same smaller memory profile; retarget it to the successful fresh
producer and pin its outputs only after full route qualification. The latest
host recheck has about 8.32 GiB available and no orphan Vivado/verification
process to reclaim. The next native build requires external RAM to be freed.

The 40 MHz cold production timedemo and full movie remain pending. Gameplay
IPC on 886e8608 is unmeasured. The earlier baseline is 0.1659957781052303 U-only
on 53f129e9 at 37.499869765 MHz, from 127 intervals with gaps spanning
cycles 8,721,490,845–19,169,282,165.

#### Resumed combined-PC implementation (October 7, 19:52 UTC)

After the user resumes, host available RAM is 23.26 GiB; the previous RAM
blocker is cleared. Fresh `ventium-pc-combined-eco-r3.tCLMI3` copies the
corrected R2 sources, preserves the five-cell count guard and bounded file
cache helper, and restores the successful R7 resource profile: 7 GiB hard,
6 GiB early stop, 9 GiB admission, 2 GiB live host reserve, zero swap and
one worker. The 540/570-second deadlines and all preservation checks remain.
No closed attempt is reused. The 22 helper tests, 82-pin/five-LUT plan tests,
actual post-route count-guard test and independent hash tests pass.

Input manifest:
`c8a8a850ae13920591121b3b55d1b8d5ea9c5fb6d99b4a18ccd4be3e25a78747`.
The guarded native implementation has started; this is not yet a qualified
checkpoint, bitstream or hardware result. No full synthesis is requested.
The board is reachable on the same reserved-memory boot, with no running
Ventium service. A fresh no-breakpoint diagnostic adapter is being prepared
in `ventium-pc-combined-board.ohqWiT`; deployment remains gated by the closed
route consumer and final bitgen audit. Current candidate gameplay IPC is
unmeasured; the labelled older baseline above remains unchanged.

#### UV/fast acceptance enforced; bounded R4 retry (October 7 UTC)

The user explicitly requires repairs in UV + fast-pipe mode. `AGENTS.md` and
`HOW_TO_RUN_FPGA.md` now forbid accepting slow/U-only/stepped controls as a
repair. The current source profile already ties `cycle_mode` high and enables
`VEN_SYS_FASTPATH`, `_RELOC`, fast flat/bounded loads, fast stores and
`VEN_FP_PIPE`/`VEN_FP_PIPE2`. The frozen define file remains
`65df5975c9fa7e63fc3252f896854599185ec127874a0923c69c6bd029180445`.
This is checked source provenance, not by itself proof of dynamic execution.

The normal RK wrapper now rejects disabling environment knobs even when an
explicit profile would override them, missing fast-pipeline defines and a
nonconstant/zero/missing/duplicate shim cycle-mode connection. Nineteen pure
Tcl-wrapper positive/negative cases pass. New read-only board guards reject
STEP, breakpoint, HALT and freeze during execution; seven unit tests cover
paired taken/not-taken, unpaired, slow, wrong-target and malformed-ring cases.
The prepared original CMP/JP64 controller additionally requires a cleared
reset observer and a primary-retirement adjacency witness across the decoded
U/V pair in S_PIPE. No CPU RTL, guest ROM, opcode or operand is modified by
these guards. They do not qualify a failed functional result.

R3's selected local route completes, but the memory watcher terminates it
during post-route preservation checks at 6,442,749,952 bytes. Native exit143,
watch exit3 and input-preservation exit0 are recorded; every observed OOM/max
event is zero. No candidate checkpoint or bitstream was produced. The last
sample has about 5.76 GB anonymous memory and 670 MB file cache. This is an
early resource stop, not a repaired CPU or routing failure.

Fresh `ventium-pc-combined-eco-r4.5BhMON` retains the identical physical plan,
corrected count/cache checks and 540/570-second deadlines. With 23.33 GiB
available, its envelope is 8 GiB hard, 7 GiB early, 10 GiB admission, zero
swap, one worker and the same 2 GiB live host reserve. It also pins and
rechecks the frozen UV/fast source contract before entering Vivado.
Input manifest:
`d947f138718fa9760784b36390809a63272b5f279ef34bd5e773e7dd4f4aa419`.
The attempt is running, not accepted. The board still has 886e8608; neither
it nor the combined candidate has a gameplay measurement. The historical
0.165995778 U-only figure counts primary retirements, not total U+V IPC and
not a verified single-issue mode. Its build/window remain as stated above.

R4 subsequently closes native0/watch0/pins0/consumer0. The candidate is fully
routed with zero route errors and zero unwaived DRC errors/critical warnings.
All original primitives, FF inputs/polarities, aliases, physical routes,
PC outputs, constant pools and clocks pass their preservation checks. Peak
scoped memory is 6,336,118,784 bytes with no observed OOM/max events; the
540/570-second deadlines are retained. Native invocation:
`5fe289b5db95406fb6544cf2eda3f6c0`. Checkpoint SHA-256:
`5fc7b087453525011308275be26eb2437348e4a923c1e3b9ac6030e02c7ed8c4`.
Independent consumer SHA-256:
`96a1f958622073f5b9fc8c494b62ecebb5ba412b1e133a043da20787bb3e3987`.
Closed-route manifest:
`4952a7fcef31d15086519b86381c71572193005db2af64f08b2e878aa85e1603`.

Final audit/bitgen in `ventium-pc-combined-bitgen.yYhium` reopens this exact
checkpoint, with input manifest
`ae50532007ef243e802892206b6366b7d3942e204751746d92118a15e27b5fb4`.
It uses the previously sufficient 7 GiB hard/6 GiB early envelope. Native
physical validity and stable Boolean equivalence do not establish silicon
correctness or timing sign-off. No processor repair is accepted at this stage.
The runtime mode checker also finds valid fast-paired retirement adjacency
in both archived OR/reversed-CMP passing controls; these remain controls,
not substitutes for the original CMP/JP64 case or Quake timedemo.

#### Combined-PC silicon microtest passes in UV + fast mode (October 7 UTC)

Final bitgen closes native0/watch0/pins0/consumer0, peak 5,116,211,200 bytes,
no observed OOM/max events. Final image SHA-256 is
`6659e0c53f3ebb6e06eaefebb1e69e8e5b76003814bbbf29f632870cdd8ef6f6`
(20,606,636 bytes); closed-bitgen manifest is
`65682ed5329e3b5317b2bd2acfb509ddfd16c11e6db909b2197c1fd54044ac6f`.
Fresh programming verifies the installed image, operating FPGA manager,
reserved DDR, unchanged production inputs and measured 39.999836260 MHz.

The unchanged original CMP/JP64 ROM completes all 64 cases, caller count64,
checksum `0xd5540`, all-zero exception record and expected AL42 exit.
Native invocation `ec863c35150b413db28e8f0bbbf4e0c6` closes0. No STEP, BP,
pairing disable, slow-path override, guest-memory repair or opcode/operand
change is used. The runtime guard passes, and the primary-retirement ring
contains adjacent CSa7/S_PIPE entries U14562 → successor1457a, spanning
the independently decoded JP at14565 without a separate primary retirement.
This is evidence of actual paired fast execution, not merely enabled defines.

All 45 exported capture files are retrieved and independently hash-checked in
`ventium-pc-combined-board.ohqWiT/exception-log-PCuFhs-export`. The full physical
RAM hash is `9e17828f718f0ca949b7a860cfb9d3c028db07912cba570496d94c271bec9e93`;
closed-capture manifest is
`1e4e30a3a3e5b4e002475e5e68b5979cef49906e1acff135c29c20d6f61ebad8`;
independent capture audit is
`7c785f61af33d560f5aa56aebf7e5c51afcd6fc899dce73856ac908873c5d031`.

The physical correction preserves both non-taken fast selection and the
taken-V raw target, using five new LUTs and no new registers. Stable Boolean
equivalence and this silicon microtest do not establish full timing sign-off
or full processor correctness. Cold production Quake, its complete movie,
and broader acceptance remain pending. Candidate gameplay IPC is unmeasured;
the older labelled 0.165995778 primary/U-counter baseline above is unchanged.

#### Cold production UV/fast run started (October 7 UTC)

The first launch leaf `ventium-quake-clock-run.6Q81Ou` stops before debugger
release: the recording watcher expected `/proc/PID/ns/time`, absent on this
kernel. Its failed watcher, launch logs and zero-frame transport are retained;
this is not a CPU workload result. `/proc/config.gz` explicitly disables
`CONFIG_NAMESPACES`. The fresh adapter accepts this independently recorded
global-clock evidence, without bypassing source pins, native identities,
clock checks or UV/fast execution guards. The actual interval predicate passes
nine positive/negative mode, clock and gameplay-bracketing cases. The build
profile's 19 cases and runtime guard's seven cases also pass again.

Fresh host leaf `ventium-quake-uvfast40-r2.KferTx`, board leaf
`/dev/shm/ventium-quake-clock-run.4FfqSO`, reprograms the identical6659 image,
checks DDR/media and measures **39.999851468 MHz** held in reset. Input manifest:
`74905023810357cb12a6bc94d289c5cdc8a573bde220f07eb6d3d29e45c316de`.
Cold daemon `ventium-quake-cold-7HSWWi.service`, invocation
`1cf0e95fd63a4ea0a79c7719000d40b8`, and passive recorder
`ventium-vcap-uvfast40-4FfqSO.service`, invocation
`b25871f91aef44da8c4ac8411e3483b4`, are running. Launch exits0; first live
samples show execution-control0, no freeze and startup progress. No snapshot,
stepping, breakpoint, guest payload change or clock fallback is used. Cold
disk is a byte-identical private clone of the preserved production seed.

The recorder streams to host storage, capped at16,384 records (about1GiB);
no full raw movie is stored on the board. Native runtime limits remain8100s.
Closure waits for three additional emitted records after daemon exit and
requires a later independent timestamp/successor audit; exit0 alone is not
Quake or full-movie acceptance. Candidate gameplay IPC is not yet measured.

Board cleanup removes only two archived16MiB RAM duplicates and the closed
microtest's seed-identical disk (52,920,320 allocated bytes), plus the failed
unreleased launch's seed-identical disk (19,365,888 bytes). RAM is fully
preserved/hash-verified in the host45-file archive; the original disk seed
and all forensic logs remain. No master image, seed or proof input is deleted.

#### Full cold UV/fast workload fails; new saved fault context (October 7 UTC)

The `4FfqSO` production run reaches the Necropolis render, then returns to
real-mode DOS. All 70 live samples retain STEP/BP/HALT clear until the later
forensic park; no clock fallback or slow/U-only override is used. None of its
engine samples qualifies a gameplay IPC interval (maximum observed
`host_framecount` is0). Candidate gameplay IPC therefore remains **unmeasured**,
not zero and not a startup-derived score. The earlier 0.165995778 primary/U
baseline remains historical, not candidate performance or total U+V IPC.

After five sustained DOS-return samples, only the identified daemon receives
SIGTERM. Its same-invocation native close is code2/status15, explicitly a
forced failure closure; recorder closes code1/status0 and host transport0.
The watcher closes1 and holds reset, preserving RAM and disk. No successful
native/standard-suite/full-movie acceptance is claimed. The recorder produced
265 CRC-valid320x200 records, sequences101–365, cycles2,128,525,556–3,032,553,838,
with maximum gap3,424,350cycles. Raw SHA-256:
`cb2e356fde313ebe6b2b73c86b54ae86399c8ade6115e2e6d8de42ac33bfbff9`.
These are incomplete-render evidence, not a complete timedemo movie.

All63 closed-run files are retrieved and hash-verified. Closed-run manifest:
`839857d27d4eb877e67be06eae6d21d31308661b6ad6917f63dc187d5a00472d`;
transport archive:
`068688ed4fd78b826019c0a8aab8df8a7dc61860d45043fcdda8822ec4e5eec9`;
physical RAM:
`af982e7210cf7d97a7ee1d26f3397087f4f4bfdf2325cdae50b9d6167eb7a35f`;
closed disk:
`c96dd84dbcf10b3017f1f2043c365af2bfb0fe13d12bcf9e12e3b3f26d7392e8`.
Offline FAT extraction of QCONSOLE.LOG has fresh startup/map text but **no
969-frame result**. The late observer-scan helper was from the older catalogue
and correctly rejected the new metadata; it provides no usable retirement
scan. The successful microtest used the matching `00cf0096` catalogue.

The exact disk's QUAKE.EXE SHA-256 is
`7cdb244122cc607cc6f162524bfcac60f6d11d8ca2ff07473d6cd962311161fb`.
Matching its intact DJGPP code page in DDR locates the initially-zero
saved-exception structure at physical14c78c. Decoding the field stores in
its actual4d61e–4d67e instructions gives vector14/error4, CSa7/EIP108,
SSaf/ESPe0810, FLAGS3206; EAX7, EBX2c91fc, ECX108, EDXeca62c,
ESI1, EDI0, EBPece08. This is **post-exit DDR residue**, not a coherent
pre-fault architectural capture. EIP equalling ECX is a clue, not proof of
a mux or return-address root cause. The old page tables are no longer usable.

Next is a fresh same-image,40MHz, UV/fast cold **forensic** run using the
existing on-chip retire comparator for CSa7/low-EIPd5c4–d611 (the independently
decoded DJGPP exception dispatch). No STEP, execution breakpoint, payload
patch or slow-mode fallback is used. Because the comparator matches only low
16 bits, its full frozen PC must qualify the capture; a hit alone is not a
fault or repair verdict. Host leaf `ventium-uvfast40-fault.ycPY4l`, board leaf
`ventium-uvfast40-fault.sJs9pv`; input manifest
`133d9e8821cc2cfc38e9fbe2a5192c1905e210721eebd9cb57181f418f43a9a6`.
The failed run's RAM and transfer-archive duplicates are removed from the
board only after complete host recovery verification; disk/logs remain.

#### Same-mode replay confirms another bad instruction boundary (October 7 UTC)

The cold forensic replay at **39.999859556 MHz** hits the actual full
CSa7/EIP4d5dc, not a low16 alias: this is the decoded page-fault dispatch
stub. Frozen snapshot records fault-PC**59682**, vector14. The DPMI frame
at physical2fb78 independently holds return10dc:2b, error4,
fault59682:a7, FLAGS3246, ESPfaef4/SSaf. Both witnesses precede the handler's
normal exception-record construction. This replay omits VGA recording and
does not establish that it is the identical dynamic failure as the earlier
production run's post-exit EIP108 residue.

Ordinary page-table translation through CR3=7e000 maps client10059680 to
physical158680. Its24 captured bytes exactly match the extracted executable:
`2b5ddc750e8b5dac2b5dd875068b5da82b5dd485db743189`. Decoding from the verified
instruction boundary gives:

```text
59680  2b 5d dc     SUB EBX,[EBP-24h]   ; length3
59683  75 0e        JNE 59693
59685  8b 5d ac     MOV EBX,[EBP-54h]
```

59682 is the SUB displacement byte, not its successor, branch target or
paired fallthrough. Thus another wrong-PC/instruction-boundary failure
remains in the full UV/fast workload after the original CMP/JP64 pass.
The trigger does not capture the originating fast descriptors or complete
pre-fault registers; it does **not** distinguish decode/length corruption,
bad next-PC selection, register sampling or another earlier control-flow
defect. No speculative RTL or timing root cause is asserted.

Controller0 means the **diagnostic capture** succeeded, not Quake passed.
All pre-freeze sampled execution controls are0; no STEP, debugger breakpoint,
single-issue override, payload patch, snapshot or frequency change is used.
The comparator's sticky forensic freeze intentionally holds reset. Native
daemon invocation `13e5d6c8847b49d8b32c4138dc921835` exits normally on its
own frozen-core detection (code1/status0, log `FROZEN latched at t=21910`);
the controller's conditional SIGTERM cleanup is not needed. This corrects
the initially recorded termination assumption: native0 is a freeze-triggered
diagnostic exit, not timedemo completion. No owner remains running. All37 closed files
are retrieved and checked. Manifest:
`39bd18dcbbedb7891b0b5ea1c1cd0085a867b4b63ce54b30d11c88b993fd4641`;
archive:
`b2f1dd74f9616b1d7e815395d58ce92d6387ded687239ce00974786042bb9a24`;
RAM:
`dbcc101ea8bc8a16e188a084c7e201695e490b7eb4ff6fd7f92a89ed4b27295f`;
offline analysis:
`0e9e4a2107af258dd3bed69d165417f073886b8c475d7b75a8af9087f4ac99d9`.

Next repair evidence must cover this exact SUB/JNE sequence and its
predecessor/call history in UV/fast mode, with taken and not-taken cases and
actual paired execution evidence. Capture the original next-PC/descriptor
state before the invalid59682 boundary, then build a directed regression
before changing RTL or issuing another physical implementation. Do not
accept the passing JP microtest or a serialized control as closing this bug.
The current image has no qualified gameplay IPC and no full standard-suite
pass; the historic primary/U-only counter baseline above is unchanged.

#### Exact SUB/JNE boundary fixture, UV/fast only (October 7 UTC)

Added `verif/sys/tests/psubjneuv/`: four ordinary cold CPL3 ROM fixtures
retain the actual53-byte chain59662–59696, physical code158000, relocated
CS/DS/SS, and the preceding32-byte cache-line seam. Each checks64 invocations
with NT,NT,T,T outcomes, including positive/negative signed overflow; variants
add read/write history, a congruent executed caller, and the preceding
indirect-CALL/ADD-ESP shape. No production guest, RTL, cache ACK, snapshot,
or FPGA image is patched. Unexecuted legacy ROM sections are explicitly
retained to reproduce the tested binaries, not claimed as workload coverage.

All four pinned Pentium-QEMU controls return native133 (AL42). The unchanged
frozen RTL model passes **32/32 UV+fast-only runs**, four histories × AXI
latencies0,1,2,3,5,7,11,13, each bounded180s and run in the existing32-job,
16GiB/128-task scope. **2,048 actual paired SUB/JNE commits** are checked:
U/V same-clock retirement, lengths3/2, exact translated address/data, defined
SUB flags, branch truth/target, no exception and terminal self-check. Every
case has64 retained memory-owner commits and30 predicted-taken/actual-not
events. No functional-mode/U-only controls were substituted. RTL/model,
profile and frozen-source hashes hold before/after; only passive C++ logging
was relinked. ROMs rebuilt from the committed fixture match all four hashes.

The first matrix is **not a pass**:20 jobs hit the deliberately small24MiB
per-file cap;12 completed but the first checker incorrectly expected the U
trace's `paired` flag to be true. This frozen DPI marks U/false and V/true;
the correct witness is adjacent equal-cycle U+V plus internal pair/commit.
The corrected checker also accounts for DPI's one-edge delay. The passing
R2 matrix narrows passive all-cycle logging to the subject range, retains
retirement/terminal observations, and uses a64MiB file cap. All native and
checker exits are0; all32 runs finish in38–75s. Old failures remain preserved.

On FPGA `6659e0c5`, variant0 completes64 cases at **39.999864723 MHz**:
physical158f00 scalars `[64,32,5355424a,0]`, all26 exception words zero,
unchanged code, EAX42/CR2=0. No STEP/BP; the primary ring contains adjacent
59680→59693 at CSa7/state28, independently spanning the paired JNE. The
original controller incorrectly expected the simulator's pre-OUT EIPf0260
and therefore closes1. Hardware instead services OUT and retires HLT;
ROM/symbols, ring and architecture consistently show OUTf0260, HLTf0261,
and terminal EIPf0262. A separate read-only, closed-artifact audit validates
this exact post-HLT finish, all self-checks and the UV witness. Native daemon
invocation `c593bec77f5e45178149efd4d8182eec` closes code1/status0 on the
late forensic freeze. **Variants1–3 have not been run on hardware.** This
passing microfixture does not reproduce or close the full Quake failure.

Artifacts: `ventium-subjne-boundary.sT8Cc6` under external/tmp. R2 outputs
manifest `cf73504656affe98abcbd7378b3ebff6ed8c07a258cd9ea79a841bd5cbf4adf3`;
results `f01fedbe669d8b583a385c86ba2346cfd4ca564cf19c20aec84a6b37d8dc9506`;
board archive `d61db2ea2b456834294f8c841b5323c614422c505c1da4c13c724d2a89d7f54d`;
independent board audit `a23d52c6cff7b6a724649d53aa33152d81bde77353242d01de2896619d4ffd40`.
Old board RAM/disk/transfer duplicates were pruned only after matching closed
host copies. The current image still has **no qualified gameplay IPC**;
the older0.165995778 primary/U-counter baseline above is not total UV IPC.

#### Earlier full-workload fault capture: trigger limitations

The existing first-`start_fault` trigger01400000 catches a **normal real-mode
IRQ0/vector8**, C000:082E, CR0=10, first IRQ acknowledge, before FreeDOS.
This is not evidence of a double fault. Source core.sv:7800/8115 routes
external interrupts through the same task/counter; the diagnostic script's
initial assumption that IRQs were excluded is disproven. Archive under
`ventium-uvfast-firstfault.Xj5EyE`, SHA
`dd938949d519c74674f4f5b962a0c348cc17c947f14a9106814604e4265f6ba6`;
native `f41537cb89944bdc9f7b896a16148870`, code1/status0. Do not use that
trigger as an unexpected-fault acceptance checker.

Read-only examination of the earlier59682 capture finds a256-entry physical
IDT at2ce88; vector14 names0018:3ab8. Its16-bit stub at physical2a578 is
PUSH DS / CALL common dispatch. A fresh cold UV/fast retired-PC freeze at
0018:3ab8 qualifies that full PC/vector14, but its first occurrence is an
earlier loader context: previous CS87, reported faultPC3d8, ~4.8M primary
retires. It is not the target Quake failure and is not classified as a new
processor bug. Archive `ventium-uvfast-pfentry.nUEq9L`, SHA
`06063d8589c0607f8203b14412d779cf824e43b19edf0180f0100bd05cb53c48`;
native `d753fcf1c6854ff889ac0620f84a7fc4`, code1/status0.

The next same-image cold diagnostic leaves that page-fault-entry comparator
disarmed through early paging, then arms it while freely running after75M
primary retirements, before the preceding103M-retirement bad-PC capture.
This is diagnostic selection only: no breakpoint, step, paired-path
suppression, architectural restore or guest edit. The trigger still needs
full frozen-PC/vector and preceding-ring qualification. No successful
timedemo, new gameplay IPC or RTL root cause is asserted by these captures.

#### Cold UV/fast trace exposes the path to bad EIP108

The late-armed page-fault-entry trigger succeeds at measured **39.999868963
MHz**. It arms without stopping execution at75,935,367 primary retirements
and freezes at189,408,572. The full snapshot qualifies0018:3ab8/vector14,
fault-PC108. Unlike the later DJGPP trigger, this capture retains the actual
preceding client primary-PC sequence (oldest first):

```text
14562 -> 14563 -> 14575 -> 14576 -> 14579 -> 108 -> 0018:3ab8
```

All five client entries are CSa7/state28. Physical11354e–11357e bytes match
the original executable. At14562 the bytes are `39 7a 10` (CMP [EDX+10],EDI),
followed by the original `75 13` (JNE1457a) at14565. The invalid14563 instead
decodes `7a 10` (JP14575). That observed branch skips the normal return
setup/pops, reaching `POP EBP; ADD ESP,10h; RET`, then108. The immediate
interrupt frame, **2-byte aligned** at physical2ff4e, independently contains
error4, EIP108/CSa7, FLAGS3206, ESPe0810/SSaf. This explains the earlier
post-DOS108 residue with direct pre-dispatch execution history. It does not
establish whether decode/descriptor corruption, next-PC selection, cache
history or sampling produces the original14562→14563 transition. Do not
call it a proven timing or arithmetic-length root cause. Ring CS at the
fault-entry transition is post-transition; its legacy linear-address field
is not used.

Every sampled execution-control word is0; production BIOS/disk are unchanged
inputs, no snapshot, BP, STEP, slow-mode control or clock fallback. Native
`2662acd1281149eea062dcd496abce0f` closes code1/status0 on forensic freeze,
controller0. Archive `ventium-uvfast-latepf.eAcGSP/closed-board.tgz`, SHA
`564ca23beaae4798f19a923d5703c9088ab18302ee063bb10011f9cb1d8c8436`;
closed manifest `f5979bfbfb5cfa146d80d18eaf98c186f3f8725b2ff0e3483b2970b9be86692c`;
RAM `3f14c58a92537c7b0084c77ef05f5ca61eac218e43899d9c19d14f8e734627d4`;
read-only audit `e1e8026079b72e409185a02f65553155b835084395ac44458b901c07223d8f36`.

#### Original JNE fixture passes; immediate caller history remains uncovered

`ventium-original-cmpjne.kp5FPr` restores the original JNE and verifies all172
prelude/chain bytes against the actual EXE; only synthetic expected outcomes
change to T,T,T,NT. ROM SHA
`6c45feb4790ba48c52a867a344c3d3d426afc09c578b7613938332b88152e82c`.
Pinned Pentium returns133; UV/fast simulations at AXI latencies0,3,7,13 each
verify64 actual paired CMP/JNE commits with exact flags, outcomes and no
exception. Each has63 retained and one immediate legal memory commit. The
original overstrict all64-retained checker rejection is preserved; corrected
closed-trace checks retain the same architectural/pairing requirements. The
latency13 run exceeded64MiB passive logging and was rerun with128MiB cap;
all four final native/consumer results pass. Output manifest
`143fdabfbded08dd66090788c401644827425c389a45c91a2b7d1044de83c9bc`.

The identical JNE ROM completes all64 cases on FPGA6659 at **39.999861276
MHz**, counts/checksum `[64,64,d5540]`, no exception, code unchanged, AL42,
terminal CS8/EIPf0258 and a qualified UV/fast pair witness. Controller0 and
native `cba125f2ba564898b86ba328effa8cdb` code1/status0. Closed archive
`22af0389d43152427baa1b4aa07b16d7f75c44485748b93052c3f5b734545d12`.
This is **not a repair**: the synthetic caller returns into case preparation;
the cold failing trace instead has immediate original RET35573→144ce.
Next reproduce that real caller/return history before attributing the cold
failure to branch condition or changing RTL. Hardware variants remain full
UV+fast; no production timedemo/new gameplay IPC/full-suite pass is claimed.

For disk headroom,32 failed original SUB/JNE-matrix owner logs were compressed
into `ventium-subjne-boundary.sT8Cc6/original-matrix-raw.tgz`; each archived
stream was hash-matched before removing its duplicate raw file. Passing R2
raw evidence remains. Host free space recovered to2.3GiB. All board RAM/disk
duplicates removed this round have checksum-verified host recovery copies.

#### Original immediate caller/RET also passes in UV + fast mode

`ventium-cmpjne-realcaller.Zz0YAT` extends the original-JNE fixture with the
actual48-byte caller35544–35573. All172 prelude/chain bytes and all48 caller
bytes match the original EXE. Case preparation now precedes the real caller;
RET35573 directly enters144ce, as in the failing cold trace. Ordinary guest
page mappings/data initialize the texture/global accesses; no restored CPU
snapshot or production guest modification is used. ROM SHA
`785356a32191b3cfbbc0b10134b94bd724e22f723940de852df7768e53001cad`.

Pinned Pentium-QEMU returns133. Four unchanged-model UV/fast runs at AXI
latencies0,3,7,13 all pass64 immediate caller returns and64 actual paired
CMP/JNE commits each (63 retained memory commits plus one immediate commit),
with exact flags/branch outcomes and no exception. Frozen source/model hashes
remain unchanged. Results SHA
`3a1de37c0c011e838fd004f638c144caf9fbbb8a25aef6c01e0a56781f3a3761`;
output manifest
`19068ba9d3a5113ccad6c22220b9d3d17374e950d8deafe0203cbc689ff30e7f`.

The same ROM passes64 cases on FPGA6659 at **39.999859668 MHz**, no STEP or
execution breakpoint, counts/checksum `[64,64,d5540]`, no exception and
unchanged code. Both the original CMP/JNE UV witness and adjacent primary
RET35573→144ce are required and present. The extra ordinary PTE stores move
the post-HLT terminal toCS8/EIPf026c; this is checked against the ROM symbols.
Controller0, native `5afff92c0f074d1faefa07cec2c1aa19` code1/status0.
Closed archive SHA
`15e903488715a398336843504967991399fc3667bfe65f3511759871d1f5153d`;
every archived file verifies against its closed manifest. Board RAM/disk/archive
duplicates were removed only after checksum-verified host recovery copies.

This closes the **immediate-caller coverage gap**, not the processor defect:
the unmodified cold workload remains broken. Wider execution/cache/interrupt
history and actual cold operands remain to be isolated. The current image
still has no qualified gameplay IPC; the older0.165995778 primary-counter
baseline above is neither total U+V IPC nor current-candidate performance.

#### Post-fault observation: reject normal IRQs and late/stale frames

The saved RAM identifies GDT2ce00, busy TSS60 at2fe72, and available TSS70
at3157a. The16-bit common handler at0018:3e80 computes the vector at
physical3166c, then FAR JMP70 task-saves the client GPRs. TSS70 resumes at
3f49 and jumps to3e98. However, a late75M-retirement comparator at3e98
catches **normal vector136**, not the target page fault: the ring shows
Quake's44d60 memory-sweep loop followed by the matching3ca0 IRQ stub. Do
not classify that capture as a new CPU defect. It also exposed a controller
polling race: the daemon closed normally on freeze between status and PID
reads; original controller1 is retained, and a separate read-only recovery
saved the already-frozen ring/RAM. Archive
`ventium-uvfast-faulttss.cYfzCy/closed-board.tgz`, SHA
`c057210e3d719f0d357af570cfe9dd4de479a7c78dc12f3f10df600a08dc6270`.

A subsequent1ms Python DDR watcher waits for vector14 and a CSa7/SSaf frame,
then manually halts without STEP/BP. It stops **too late**: the apparent
error word is EBP/ece08 and the frame PC has become4d6d4; the original error
has been stripped and guest exception dispatch has advanced. TSS60 retains
CR2-copy10000108/error4, but its live GPRs now belong to4e871, not the fault.
Neither the frame nor the halted register scan is accepted as the original
bad-CMP operand capture. Controller0 means only capture completion. Archive
`ventium-uvfast-pfhalt.y9SLU0/closed-board.tgz`, SHA
`c992d12f9d2968c5ef7419ba5ef910f832904a9aa9787235ebb72c383f334788`.
All closed files in both archives verify. Board transfer/RAM/disk duplicates
were removed only after checking their matching host copies.

`fpga/board-tools/watch_dpmi_pf.c` replaces the slow polling path with a
bounded native diagnostic. It reads DDR only and makes exactly one possible
control write: manual HALT **after** observing fresh vector14 and two matching
complete CPL3 frames, including a valid error-code shape. Aligned loads handle
the2-byte-aligned frame. It rejects STEP/BP/HALT/freeze/reset while watching,
has a300s deadline, and never alters clock, guest RAM, comparator or execution
mode. The pinned launcher must first validate reserved DDR and image/guest
hashes; this is not a general-purpose unqualified `/dev/mem` tool. Host normal
and ASan/UBSan self-tests pass; the AArch64 binary also passes its self-test
on the board. This debugging improvement is not a processor fix or IPC gain.

#### Native post-fault halt captures the original SUB interior-PC failure

On unchanged image6659 at **39.999859644 MHz**, the native watcher arms at
75,000,015 primary retirements and detects a fresh frame
`[error4,EIP59682,CSa7,FLAGS3246,ESPfaef4,SSaf]`. HALT acknowledges18.890us
after the matched-frame timestamp, before TSS70's first instruction at
0018:3f49. No prior execution halt, STEP, BP, guest edit or comparator is used.
Controller/native-watcher0; daemon `0e96aef496a24e1895a62dc75c3cd823`
closes code1/status0 after the **later** archival forensic freeze.

The uninterrupted client ring contains `5967d -> 59680 -> 59681 -> 59682`.
The actual bytes at physical158680 are `2b 5d dc 75 0e`: SUB EBX,[EBP-24h]
at59680, JNE59693 at59683. Entering59681 instead executes POP EBP;59682
then decodes an x87 memory instruction. The ring shows the lazy-FPU handler
0018:40a3..40af returning to59682, followed by the page-fault handler. Current
CR2 is1000008c. Every original53-byte chain byte matches the EXE.

Unlike the reset-only capture, this preserves task-saved client GPRs in old
TSS60, physical2fe72, before common dispatch edits that TSS:
EAX7ec, ECXc, EDX0, EBX0, EBP7e, ESI51eb851f, EDI59948. Its savedESP384a
and CS18/EIP3e98 are the **handler** stack/continuation, not clientESP/EIP;
use the actual fault frame for those. Original prologue bytes and stack
cleanup reconstruct pre-POP ESPfaef0/EBPfaf74. Ordinary page walking maps
both SUB operands to physical1fff24/1fff50, each value13h, while the
accidentally popped stack word at1ffef0 is7eh. Thus the retained resultEBX0
is consistent with19−19; the illegal POP explains EBP7e, and its following
x87 address gives10000000+7e+0e=**1000008c**, matching CR2. Pre-POP EBP is
a code/stack reconstruction, not a directly sampled register.

The last-retirement observer now belongs to FAR JMP3e93, and the retained
memory packet belongs to POP59681. Neither is falsely labelled the bad SUB
commit. We still lack its effective U/V lengths, pairing decision and
next-PC selection at the failing edge; no cache, decoder or timing root
cause is asserted. This does establish a remaining **cold UV/fast interior
PC defect**, not a failure cured by U-only serialization.

Archive `ventium-uvfast-nativepf.Y0YPrY/closed-board.tgz`, SHA
`b964d6e37685a2e52db630ef7f70e0e115a48e71e144379490977530cd3d04fc`;
RAM `02b8e7e3c9ec97f8557bed9d897c35057fc10255ded3db80e788496289455f36`.
All closed files and the read-only `audit_nativepf.py` checks pass. The current
candidate still has no qualified gameplay IPC or full standard-suite pass;
the older0.165995778 primary-counter baseline remains labelled above.

#### Exact cold SUB operands/layout: 32 simulations and four hardware controls

The native post-fault capture motivates a **new** fixture, not another use of
the earlier64-case1/1/overflow test. `psubjneuv/subjne_cold.S` preserves all
53 original bytes at59662..59696 and reconstructs the captured precommit GPRs,
ESPfaef0/EBPfaf74, ordinary FA000→1FF000 stack mapping, operands19/19,
FLAGS3246 and later minute comparison52−58. Its16 subject comparisons must
all continue59680→59685; the later minute comparison takes59693 normally.
Plain, congruent D-pressure, congruent I-pressure and combined variants use
only ordinary guest accesses. They do **not** reproduce the whole cold boot,
interrupt history or cache contents.

All32 cases (four variants × AXI read/write latency0,1,2,3,5,7,11,13) run in
parallel against the unchanged pinned107-define model and pass:512 same-clock
U/V subject commits, of which508 are retained memory completions and four
immediate. The passive observer requires exact precommit registers, owner,
effective lengths3/2, physical read1fff50/value19, branch truth/target and
FLAGS3246. No exception or interior-byte execution occurs. All four pinned
QEMU controls close133. Source/model/179 frozen-input hashes remain unchanged.
Suite exit0; output manifest
`8451e8a11918e937b923180ddf3bff1c5c268c7930a306dcb09b6825473b4527`.

The same four ROMs each pass16 checks on FPGA6659, with no STEP/execution BP,
zero exception records, unchanged original code, finalCS8:EIPf029e/EAX42,
and adjacent-primary witnesses spanning SUB/JNE. Each controller/native closes0.

| Variant | Measured MHz | Closed archive SHA-256 |
|---|---:|---|
| Plain | 39.999858780 | `db44ec7a2120fd4ca2094d34bf52e5a1c9ed36d08b2458b3c4a408d39f56de9c` |
| D-pressure | 39.999854428 | `e38311b635d40809d4452553a113aac55b76e0d05451b0ee1ca970f80c2dc415` |
| I-pressure | 39.999858628 | `e015b6af39d1136787020eb301ebdb82a5463fb76c1e585071d0649011177b51` |
| Both | 39.999854308 | `b33c1f571de5cd0480a0349d4505d54852842fbf866c1b70d28d9eee0fb06e5b` |

Host root `ventium-subjne-coldlayout.SRrOMS`; each archive's54-file manifest,
RAM, ROM, clock, scalars and native invocation are independently checked by
`audit_board.py`. After recovery, only the four duplicate board RAM dumps and
unchanged private seed copy are removed; captures remain recoverable from the
host archives and seed. No firmware, original media or useful evidence is lost.

Repository `build_cold.sh` reproduces all four measured ROM hashes. The optional
bootstrap additions leave all four legacy hashes unchanged. `check_cold.py`
rechecks all32 closed cases and rejects seven negative controls (functional
mode, pair, length, operand, outcome, target, flags). These are additional
coverage/results, **not a processor repair**. Current6659 has no qualified
gameplay IPC; older53f129e9's0.165995778 primary-counter baseline over qualified
intervals in cycles8,721,490,845–19,169,282,165 predates this image and is not
total U+V IPC. Full cold Quake and standard-suite acceptance remain open.

#### Invalid-SUB breakpoint replay: inconclusive capture, not acceptance

A separate unmodified cold replay arms execution BP59681 only after75M primary
retires. This address is inside SUB59680, not its intended V at59683; the
source's equality-only V breakpoint predicate does not suppress the correctly
decoded pair. However, a transient malformed raw length could still alter
pairing, and BP is EIP-only, so this remains **intrusive diagnostic history**.
No STEP, clock reduction or slow-mode fallback is used. Do not label it clean
workload acceptance even if it were to complete.

It does not hit59681 before the300s deadline. Controller1 is retained;
the bounded cleanup sends SIGTERM to the native daemon, whose closed record
is code2/status15, invocation `ad9b2eb7f97d4c2891e1b6c8b555120b`.
There is no bad-SUB commit capture. Later read-only core-ring text shows
CSa7/ESPe0810, traceback108 and the DOS prompt, consistent with the other
previously observed failure path; this text alone does not prove its original
CMP transition. DDR B8000 is all zero on this platform and is explicitly
**not** treated as a blank-screen verdict.

Root `ventium-uvfast-invalidbp.L1epO6`; all files in the closed manifest verify.
Metadata archive SHA
`5235d8f72cb9a232bad25e9afc3e62d59fc9479963335f6e996fb3b4dc45ef6d`;
separate changed-disk recovery archive
`1eec1fca30fdd01f04d9c4508a2957f7278a57968247ee0b7006079dd5326e36`
restores exactVHD `4c6579c0f6b6116fa07e3a65c663517bea1a78f4807994b19581b17931ba8a6b`.
Later ring-text hash
`0ddc33bf206c7598d56a3895c58c22090e27fdedf2ac4ae7c8fa5912036419ba`.
Only board disk/archive duplicates are removed after host verification.

The complementary BP14563 replay (inside CMP14562, not intended-V14565) also
misses its target, this time for150s; its final ring text instead contains
traceback59682 and the DOS prompt. Again this is not proof of the earlier
transition or evidence that a breakpoint repaired either path. Controller1;
bounded SIGTERM closure code2/status15, invocation
`e181e312fca345679c621b712c5be790`. Measured39.999858308MHz. Root
`ventium-uvfast-invalidcmp.zn6YTG`, archive
`cabd278ba1e4b287619d88aa0aeda879c4787aac42434c3d856e65a20512bafe`:
all33 files verify, including the private VHD which still equals the seed.
Its board VHD/archive duplicates are pruned only after that host audit.

**Next discriminator:** retain selected primary commit records passively,
without execution breakpoints, across either cold failure. The existing
recorder overwrites the desired commit with later POP/handler retirements;
the native post-fault halt captures task state but cannot recover that edge.
Before any debug ECO, check reuse of the existing retire comparator as a
record-enable filter (freeze disabled), preserve all CPU routes/function,
and validate observer reset/readout behavior. This is a proposed debugging
direction, not an implemented processor fix. Do not replace the original
failing workload with another passing short fixture or serialize its pipeline.

#### Passive retirement filter: closed logic and physical checks (Oct 7)

The recorder can now retain selected primary retirements without execution BP,
STEP, slow-mode override or comparator freeze. This is **debug instrumentation,
not a processor repair**. CPU6659's logic and UV+fast profile remain the baseline.

Native inspection initially found that the original comparator's last-PC RTL
registers were synthesized away (their shim outputs are open). Its16 counter
FFs do remain. Their shared CE is proven, over148 mapped signals and85 FF
cutpoints, equivalent to the complete enabled/unfrozen CS/low16-PC retirement
match. Both the conditional and unconditional mismatch queries are UNSAT after
a nonvacuous SAT check. The second export omitted constant-cell types and its
consumer failed; the third exports native VCC/GND types explicitly and passes.
Nothing is inferred from a constant's name. Closed query root
`ventium-retire-filter-query-r3.1X9GDe`, native data SHA
`0e7afebc7e588b0c4befa5fc4fa702f6b456cf52c88897a2f339504efb9c8926`.

The ECO reconnects only `ven_retire_scan_retire_enable_buffer/I0` to that
existing CE and changes the observer metadata from`00cf0096` to`00df0096`.
No new LUT/FF, CPU function, clock, reset, site, BEL or pin-map changes.
Native audit checks298196 primitives,236980 FF input polarities,329 hierarchies,
561400 literal non-target route aliases and all pre-existing CPU sink paths.
Only nine nodes/pips on the old observer-only branch are trimmed; the150-record
FF CE output route is unchanged. All225637 routable nets are fully routed;
zero route errors, DRC errors or critical warnings. The queried record0 CE
setup path has15.687ns margin at40MHz (path-only check, **not core Fmax sign-off**).

The first ECO stops cleanly at its7GiB early memory limit (native143/watcher3,
pins0), without OOM or a usable checkpoint. A separate10GiB-capped retry closes
native0/watcher0/pins0, peak8,657,080,320bytes and no OOM/max events. Root
`ventium-retire-filter-eco-r2.hIwsVL`; checkpoint SHA
`189dcefe72d2b27a43122389f9f1ca1f5ae08037b655cf1afcc811c74d44b817`;
closed-route manifest
`8149d6f930edbdf76cdd3b8ce4acac6a1a08d813a41684341bbcb81a41624955`.

Offline checks:2048 metadata truth cases; vendor primitives8192 clock cases
(522 matching captures,7605 holds,65 resets);12 reader tests including150
record and338 live-packet onehots;19 UV+fast profile and7 runtime-guard tests.
The new reader explicitly separates **historical filtered retirement** from
the **live retained packet/current halted architecture**. It does not label
raw live decode fields as the effective retained packet. Old image metadata,
inconsistent scans and out-of-filter PCs are rejected. Filter CS is not sampled;
configuration CS+EIP-care/no-freeze receipts are required because the write CSRs
have different read meanings and cannot provide configuration readback.
Program the range under held cold reset: its bit31 also toggles PS coherence.

Hardware calibration and original cold-workload replay follow separately; none
of the above is timedemo acceptance. Current6659 has no qualified gameplay IPC.
Older53f129e9's0.165995778 primary/U-counter baseline, over qualified intervals
within cycles8,721,490,845–19,169,282,165, predates this work and is **not total
U+V IPC**. One obsolete board firmware copy (`ventium_fpga40_debugscan.bit.bin`,
20MiB) was removed only after matching host-backup SHA3be5b6e4…54ff14d; it
remains recoverable from `ventium-debugscan-bitgen.0Neit8/native-output/`.

#### Filtered image: successful hardware calibration, not a CPU fix

Bitgen closes0 with zero physical errors and unchanged inputs; image SHA
`ef01263f5e8cca781ec1dbdf279a31022457491fb828212092393e1f8970a57f`,
20,606,636bytes. Root`ventium-retire-filter-bitgen.CaBl0i`, closed manifest
`c40478bf919422d828b2fba56eb136b96d4e8dda3242a13906013e429b5545b4`.
Peak5,018,591,232bytes, no OOM/max event; Vivado is closed before deployment.

On hardware, the unmodified cold-layout16-case SUB fixture passes with this
image at39.999858572MHz. Programmed under held reset:CSa7, low16PC9680 exactly,
cfg`000700a7`, range`96809680`; comparator freeze/STEP/BP remain disabled.
The new record clears under reset, then retains **59680→59685** after the
guest continues through its normal final HLT atf029d (halted EIPf029e).
Record state28, ACTIVE0, live lengths3/2, JNEcc5, both observed PF bits1,
known EIP-D59685 and primary/state-mux bit2=1. These fields are a healthy
calibration, not the missing cold-failure observation. A separate adjacent
primary ring witness confirms the paired fast path at59680→59685.
All16 result counters match, no exception record, native/controller exits0.

Host root`ventium-retire-filter-board.W8CYgp`; `audit_calibration.py` verifies
the44-file manifest and archive
`c777e55bc0f3c3c5facc79ea914c72c0c7b93d752bfe87107e689c56c1e2f47e`.
Only duplicate board RAM/private seed/archive files are removed after recovery;
the complete capture and unchanged seed remain recoverable. An initial manual
host check expected the last OUT PCf029c; independent byte decoding confirms
the subsequent HLTf029d retires too. The persistent checker requires that F4
byte and next-PCf029e; no captured data is altered to satisfy it.

Cold production replay follows with the same image/profile, original BIOS/VHD,
no guest code edits and no stop before the existing native post-#PF watch.
Currentef01263f has **no qualified gameplay IPC** or timedemo acceptance; the
older53f129e9 primary-counter baseline and its qualifications above still apply.

#### Passive cold replay captures the actual bad CMP retirement (Oct 7)

Two original cold BIOS/VHD replays run on `ef01263f` with UV+fast enabled,
`cycle_mode=1`, no STEP/execution breakpoint and no comparator freeze. Only
the passive record filter changes between runs. The native watcher halts
**after** a fresh guest #PF; this is fault localization, not a performance run.
The first run filters SUB59680 and retains its healthy59680→59685 record;
the failure instead follows the previously seen CMP14562 path. The second
run filters CMP14562 and finally retains the **faulty14562→14563 commit**.

| Cold run | Measured MHz | Retained primary→next PC | Archive SHA-256 |
| --- | ---: | --- | --- |
| SUB filter | 39.999861044 | `59680→59685` (healthy) | `bfba868f5ba310d05d188e082aaa21a4dde52664f7d6d1319de1913aaa180591` |
| CMP filter | 39.999857204 | `14562→14563` (**invalid**) | `745fa06e07fd2d27322511c6000bd79389d6e40875dacdfe8ef2b1e021c648c5` |

Both native/controller exits are0. Each41-file capture manifest verifies under
host root`ventium-retire-filter-board.W8CYgp`; `audit_cold.py` independently
binds the image, reset/config receipts, closed native invocation, ring, RAM,
original executable bytes and page translation. Its result is explicitly
`PASS_BOUND_COLD_CMP_FAILURE_CAPTURE_NOT_CPU_ACCEPTANCE`.

In the bad record, primaryPC14562 and architectural nextPC14563 are valid;
previous state is28 (`S_PIPE`), sampled ACTIVE0, raw live lengths3/2, JNEcc5,
EIP-CE1 and both observed PF bits1. **ZF and actual `do_v` are not recorded.**
The low three sampled primary-PC mux bits[2,3,4] are0,0,0; state-mux bits are
0,1,1. Mapped selector0, state gates14=1/31=0 and FP override0 are observed.
The pre-EIP-D known value is14542 with maskffffffdf (bit5 is unavailable).
Its known bit0 differs from the subsequently sampled architectural nextPC.
Therefore these intermediate taps are **not proof of a settled, coherent
combinational word**. They do not establish a bad effective length, flags
fault, replicated-owner disagreement, or physical timing as the root cause.
The live retained-packet bank belongs to laterPC14575, not this historical CMP.

RAM page translation (`CR3=7e000`, linear10014562→physical113562) preserves
the exact original bytes `39 7a 10 75 13`: CMP length3 followed by JNE length2.
Legal continuations are14565 for U-only,14567 for paired not-taken, or1457a
for paired taken. **14563 is none of them.** The ring independently records
14562→14563→14575→14576→14579→0018:108, followed by the #PF handler.
Execution at the CMP's interior byte decodes JP14575, bypasses the ordinary
epilogue, and reaches the wrong RET; the native frame is
`[4,108,a7,3206,e0810,af]`, CR2=10000108. Post-fault HALT acknowledgement is
19,360ns in the CMP run; no pre-fault stop was used.

The changed private VHDs are preserved in their complete archives, not silently
replaced by the seed. CMP-run RAM SHA
`02573e90d57024aafd05a2b95c93c7691037af8ac309910a00f2c7a758c2df58`;
VHD SHA`c5d2dc4e0c09ac15ab0679611b9973f01001ecf930282b560b71443bfd64d9d9`.
The next investigation is effective next-PC arithmetic/selection and packet
ownership. Existing `u_tgt_raw`/`v_tgt_raw` are already combinationally
precomputed in RTL; merely renaming them is not a new optimization or fix.
Earlier mapped mux/cofactor proofs did not prove the carry-chain arithmetic.

No processor repair, standard-suite pass, or full40MHz timedemo completion is
claimed. Currentef01263f still has no qualified gameplay IPC; the older
53f129e9 **0.165995778 primary/U-counter IPC** baseline over qualified intervals
spanning cycles8,721,490,845–19,169,282,165 predates it and is not total U+V IPC.

#### Mapped low-PC arithmetic and replicated-owner checks (Oct 8 UTC)

Two read-only queries reopen the exact deployed-image checkpoint189dcefe…
without synthesis, routing, clock changes, checkpoint writes or deployment.
Both close native0/watcher0/pins0, no OOM; peak cgroup memory3,653,398,528 and
3,597,258,752bytes. Their native exports are:

- `ventium-pc-arithmetic-query.zoY5W9`:14299 cells, SHA
  `79b75ef558632ca57909d86940af0653785f1ff3e3d4174fd724033baa83cec1`.
- `ventium-pc-select-query.8GHmDW`:1095 cells, SHA
  `a4577598eaa96e35ea95053f00c7cbbd10c6ef53ca62932f43b0418ccc2dc897`.

All899 overlapping cell descriptions and5252 pin bindings agree. The low-three-
bit fall-through carry network is proven equal to ownerPC+Ulen+Vlen modulo8
for both live and retained packets, **conditional on coherent ACTIVE copies
and32-bit code mode**. The64-signal arithmetic model has no opaque inputs
other than its explicitly declared raw decode/FF cutpoints; both nonvacuous
SAT/UNSAT miters pass. This is not a whole-word or physical timing proof.

A separate primary-PC miter covers the observed no-redirect integer path:
with native state copies atS_PIPE, CS.D copies1, no raw FP override and
coherent owner copies, primaryPC[2:0] equals
`(ownerPC + Ulen + (mapped_pair_enable ? Vlen : 0)) mod 8`.
Both live/retained nonvacuous miters pass. Missing/unneeded branch/BRAM cones
remain independent opaque variables, not guessed constants; UNSAT holds for
all of them. This proof does **not** identify actual `do_v` in the bad capture
or show that its sampled controls were stable/coherent at the CPU edge.

Eight physical ACTIVE FFs exist. Their local next-state LUTs all implement
the same shared-data/shared-select mux, but use different replicated feedback
Qs. INIT, clock, CE, reset and inversion checks agree; an additional miter
proves equal previous copies imply equal next copies. Thus **there is no
demonstrated logical divergence of these replicas in a zero-delay synchronous
model**. It would be incorrect to call their replication a proven RTL bug.

There is nevertheless an important observability gap. In the mapped post-PC
adder, `pipe_mem_active_q_reg_rep` selects both the U length and V-length bit1;
other copies select the PC and other V-length bits. A deliberately inconsistent
model (only that replica1, original sampled ACTIVE0, raw lengths3/2, retained
lengths1/0) can produce the observed low-bit +1 advance. This is a **hypothetical
counterexample to trusting one sampled ACTIVE bit**, not evidence that it
occurred. The historical capture contains only the original ACTIVE bit; the
eight-copy live scan after #PF cannot resolve this question retrospectively.
The primary mux also contains a slow-decoder-length arm controlled by replicated
state bits, which likewise was not individually observed on the failing edge.

Next discriminator: replace redundant high EIP-D/relative-displacement sampler
slots with historical owner-copy, primary-selector, effective-length and pairing
controls. Keep original CPU function/routes intact and the passive filter active;
validate reset, metadata, readout and paired hardware controls before another
original cold replay. Do not merge owner logic or serialize memory retirement
merely because the hypothetical model can reproduce +1. No processor repair or
new gameplay IPC is claimed. Both native queries are closed; board RAM/VHD/tar
duplicates from the CMP capture were removed only after exact host-copy checks
and remain recoverable from its archive.

#### Historical owner/control observer, ABI9 (Oct 8 UTC)

The next discriminator is now implemented without a CPU change. Observer ECO
`ventium-owner-observer-eco.bN2OVZ` reuses18 existing pre-sampler inputs: seven
additional ACTIVE copies, primary outer/inner selects, effective U-length[2:0],
post-pair-gated V-length[2:0], and three mapped pairing terms. The original
ACTIVE sample remains. Full primary/nextPC and the earlier PC-vector taps stay
available; sacrificed EIP-D/relative-displacement bits are explicitly unknown,
not silently reconstructed. Metadata is `00ff0096`, catalogue SHA
`20884975c87fd5c2af4ff489bd1563b9a0ceadbb25c8ecc570d13993356fdc74`.

Native, resource-watch and input-pin checks close0. Independent consumer passes:
298196 primitive functions/sites/BELs preserved except one observer metadata LUT
INIT; no new LUT/FF;236980 FF input polarities,329 hierarchy protections and
561168 non-target route aliases unchanged. All existing CPU sink paths remain;
only201 nodes/190 pips on the removed observer branches are trimmed. All nets
route; DRC errors/critical warnings0. The seven additional owner-Q sampler
paths pass setup and hold (minimum margins22.680/0.357ns at40MHz). These are
**observer-path checks, not whole-CPU timing/frequency sign-off**. Peak cgroup
memory8,677,531,648bytes, no OOM. Route closure SHA
`5355f120d9af9c1f0a888595fe20ee0049b1ffef68d6ed0b4f812e3b6d19b522`.

Reader14 tests pass (all150 historical and338 live one-hot bits, all256 ACTIVE
combinations, old-ABI rejection, halt/coherence/filter guards). Vendor primitive
test passes8192 edges,4101 captures,4006 holds,85 resets and64 metadata cases;
the complete32-word metadata truth-table test covers2048 cases. The first vendor
test's time-zero LUT-input event mistake is retained in its failed log; the
corrected fixture changes initialization stimulus, not hardware truth tables.

Closed bitgen `ventium-owner-observer-bitgen.Ks9Q3e` produces image
`c2ce7e80a877926596b4492ee3c36fb21e636107572dc2e25f0383c3cc6eae2d`.
Native/watch/pins0, peak5,018,951,680bytes, no OOM; no second Vivado instance.
Bitgen closure SHA
`4cf103480e23697044183f9ae8d4af5bc8ee6a7c77af478fe1c67e6065ee51c0`.

Paired hardware calibration passes all16 SUB/JNE cases at39.999862060MHz.
Historical59680→59685 survives subsequent HLT retirement; all eight ACTIVE
copies0, effective lengths3/2, pairing-term OR1, outer select1/inner select0.
Reset record is zero; no STEP, BP or comparator freeze. Host audit verifies
the original micro-ROM, zero exception record, RAM, seed VHD and closed native
invocation `1f5552c0424f47fba8802cf83ddba1e9`. Capture root
`ventium-owner-observer-board.xS4gL9`, archive SHA
`c6e00da8378dd80fde1bf9991e57a1efe0cf152cd82e38d557709f7ef100de79`.
Its board RAM/VHD/tar duplicates were removed only after exact host-copy checks.
The obsolete installed53f129e9 firmware copy was similarly removed to make
deployment space; its identical host bitgen artifact is retained.

This calibrates observation, **not a processor repair**. Original cold Quake
replay follows. Currentc2ce7e80 has no qualified gameplay IPC or full timedemo
acceptance; the older53f129e9 **0.165995778 primary/U-counter IPC** baseline
over qualified intervals spanning cycles8,721,490,845–19,169,282,165 predates
it and is not total U+V IPC.

#### Cold replay: sampled owners and effective lengths are coherent (Oct 8 UTC)

Original unmodified cold Quake on c2ce7e80 reproduces **14562→14563** at
39.999860660MHz. No STEP, execution breakpoint, comparator freeze or restore
precedes the fault. Native invocation `6801aece88b749e789e5d9ceb667d48d` and
controller close0. This denotes a successfully captured **failure**, not a
successful timedemo. The41-file host audit binds original executable bytes
`39 7a 10 75 13` at physical113562, the retirement ring, RAM, private changed
VHD and native post-#PF stop (23,011ns acknowledgement). Frame remains
`[4,108,a7,3206,e0810,af]`. Archive SHA
`9c86c49635b8c8292c1036ebbcd042b733e8954764ef6f44c3dadf45412214a6`
under `ventium-owner-observer-board.xS4gL9`.

The expanded **historical** record now observes all eight ACTIVE copies0,
effective U length3, post-pair-gated V length2, pairing terms0/1/0 (OR1),
primary outer select1 and inner select0. The old observation of state28,
mapped redirect0, integer fast predicate1, and primary bits[2,3,4]=0/0/0
is reproduced. Therefore neither a **sampled** owner-copy disagreement,
wrong effective low length, disabled pairing nor selection of the slow-decoder
primary arm explains this record. Actual architectural `do_v`/ZF still are
not directly observed. Combinational taps still are not a settled waveform:
pre-EIP-D14542 (mask00ffffdf) differs even in known bit0 from actual next14563.
Do not convert these samples into a proof of electrical timing, or claim that
all controls were stable throughout the setup/hold aperture.

The CPU failure remains open. Focus moves to the fast next-PC data path;
another U-only/slow-mode success cannot close it. Board RAM/VHD/tar duplicates
were removed only after complete host verification; all remain recoverable.

#### Concrete candidate: narrow length sum and late pairing selection

`ventium-fastpc-pair-reassociate.N8f4hf` implements an **isolated, not yet
integrated** candidate for the integer no-redirect PC expression:
compute the unconditional5-bit `Ulen+Vlen`, compute U-only and paired PC
advances in parallel, then select with `do_v`. This takes the late pairing
decision out of the carry inputs. It adds no clock, bubble, pairing restriction,
guest-specific predicate or state repair. Preserve existing U-width wrapping
and the separate V not-taken redirect's intermediate-width semantics during
integration; do not merge those expressions indiscriminately.

Full32-bit SMT equivalence passes nonvacuous `sat/unsat` for all PC values,
all4-bit U/V lengths, both code widths and both pairing decisions. A second
nonvacuous witness proves14562+3+2=14567 for the no-redirect case. RTL simulation
and independent Vivado-mapped vendor-primitives simulation each pass73,728
directed/random vectors, including16/32-bit wrapping and sums above15.

Two independently synthesized OOC leafs, same part/tool/options, give:

| Isolated PC leaf | Current expression | Candidate |
| --- | ---: | ---: |
| LUTs | 81 | 59 |
| CARRY8s | 12 | 8 |
| CARRY8s downstream of pairing input | 6 | 0 |

That is27.2% fewer LUTs and33.3% fewer carry primitives **in this leaf only**.
Synthesis closes0, one guarded Vivado family,4GiB cap. These are not whole-core
area savings, placed timing/Fmax, a gameplay gain, or proof of a hardware fix.
Mapped structural export SHA
`6b5bbc954bf3ac4c11d0ecd38c1e6e0c5f1444d2b801017e99f931de7cbeab6c`;
candidate/test source SHA
`686fb9a24c2b203c159cdfedd2474b90489419f115ac3b31f4858be8272c2daf`.

Next: integrate the general expression without touching flags/admission or
adding a slow fallback; run the differential and UV/fast integration gates,
then validate original cold Quake on hardware. No production CPU RTL was
modified in this observer/candidate study. Currentc2ce7e80 still has **no
qualified gameplay IPC**; the older53f129e9 baseline remains0.165995778
**primary/U-counter** IPC over qualified intervals within
cycles8,721,490,845–19,169,282,165, not total U+V IPC.

#### Candidate integrated; UV+fast simulation checks (Oct 8 UTC)

The preceding isolated candidate is now integrated in commit `f710e890` in
`rtl/core/core_fastpath.svh` (SHA-256
`11e402fcfb11e1ac8a26e394ba8c6e388d80e3e591faaf8dcb05d5dcfe4b5a29`).
Only the U-only/no-redirect paired PC arithmetic changes. Flags, admission,
retirement cadence, branch selection, debug controls and the V not-taken
redirect expression are unchanged. There is no added slow fallback or
application-specific condition. This is a structural candidate, **not a
demonstrated hardware root-cause repair**.

The repository regression `verif/pc_advance/run_gate.py` extracts the actual
marked production expression and binds its normalized hash to the SMT model.
It passes all 73,728 vectors and both nonvacuous full-domain/witness miters.
Instructions and limits are in `verif/pc_advance/README.md`.

Two distinct integration builds were checked; do not conflate their profiles:

1. **Current working-tree default profile**, isolated binary under
   `ventium-fastpc-core-verify.SKowfW`: `make verify` closes **0**,
   108/108 functional QEMU comparisons pass and all gating M4/M5 metric bands
   pass. The 20 non-gating per-instruction cycle comparators remain divergent
   and are explicitly reported, not silently counted as clean. This default
   gate is not hardware-profile or UV+fast system acceptance. Its initial
   source-hash list omitted `fp_shared`; no `fp_shared` edit was made, but the
   list is not a complete pre-build source manifest.
2. **Frozen hardware RTL plus only this PC-expression delta**, under
   `ventium-fastpc-full107.ScwSbb`: all original 179 frozen inputs verify before
   and after. A private copy contains the changed fragment; original inputs
   remain untouched. All 107 simulation defines match the 110 hardware defines
   minus exactly `SYNTHESIS`, `VTM_NO_DPI` and `VEN_ALTSYNCRAM_XPM`. Shared FPU,
   relocated system fast path and fast memory remain enabled; no new
   `VEN_SYS_FASTPATH_ALL` or U-only configuration is substituted. This build
   uses the previously reviewed external reset-edge harness, with assertions
   enabled and passive reset/initial-RAM receipts. Binary SHA-256:
   `ba46febbd048bd7dbd578568fbcf5470bcf3fc34e8e7c875468ad488348b16fd`.

The hardware-profile matrix has **32 native/consumer passes**, all
`cycle_mode=1`, with no debugger STEP, intended-V breakpoint, restored state or
forced architectural values. It covers ordinary and cache-line-last-word memory
CMP/JNE fixtures, AXI read/write delays 0/3/7/13, random-initialization seeds
17/31, and both cycle and paired full-state trace formats. Every cycle-format
case observes all 16 CMP/JNE pairs retiring in U/V at the same clock, both taken
and not-taken destinations. Paired full-state cases check produced ZF, operands,
relocated protected/paged context and terminal success. All 16 corresponding
cycle/full-state PC streams match. These are directed tests, not a gameplay
measurement or the standard suite.

The initial matrix is retained as **FAIL**: 12 consumer passes, 20 failures
after the harness's 400-clock idle threshold stopped delayed-AXI bootstraps
before all CMP windows. Separately named `r2-quiesce200000` restores the
established AXI idle threshold; all 32 then pass, with the same binary, ROMs,
seeds and delays. Native jobs remain individually capped at 90 seconds and
2 million cycles. No RTL was changed to obtain the rerun pass.

No new FPGA deployment or standard-suite completion is claimed. The deployed
`c2ce7e80` still reproduces the original cold bad-PC commit and predates this
RTL candidate. Both have **no qualified gameplay IPC**. The historical
`53f129e9` baseline remains **0.165995778 primary/U-counter IPC**, not total
U+V, from 127 qualified intervals with gaps within cycles
8,721,490,845–19,169,282,165 at 37.499869765 MHz.

The complete post-PC mapped-arithmetic query is now closed. Its first attempt
stopped at the declared 20,000-cell export bound; no design was modified.
The separately named R2 query follows every actual CO7-to-CI chain connection
and exports bounded local cones (42 roots, 989 cells). Native/resource/pin
checks all close 0, peak memory 3,593,801,728 bytes, no OOM. Export SHA-256:
`b841ccf09f13e37c4df2134cd2eb138ef6d52d3b1b32bf54f6fb2284ab41b0f8`,
under `ventium-fastpc-map-query-r2.j4uJMV`.

Eight nonvacuous full-word SMT miters pass: native POST32 and POST16 equal
owner-PC + U-length + enabled V-length modulo their widths, for both live and
retained owners and both CS.D modes. The models have **no missing/opaque
combinational inputs**, only explicit raw decoder/pairing cutpoints and FF
state. They require coherent physical owner/mode replicas; they do not prove
electrical stability at the capture edge. All overlapping descriptions in the
earlier arithmetic export agree. This establishes useful complete-word
replacement boundaries, not a root cause, hardware timing sign-off or CPU fix.
No full synthesis, route change, new checkpoint or deployment occurred.

#### Prepared localized hardware-test plan (not yet implemented)

`ventium-fastpc-eco-plan.aFM8Dc/plan.json` describes a general post-PC
replacement at those proven boundaries, SHA-256
`334505ad40e72656f1b97ce459182c73ef9a47c3e83657218b018af11f002f4e`.
It reuses the native U-only sum, computes the paired sum in parallel and
selects after addition. All 48 original POST32/POST16 output sinks are
explicitly enumerated. No flags, admission, branch-redirect, clock, reset,
retirement or FF changes are proposed. There is no guest-PC match predicate.

Eight native-old-versus-proposed complete-word SMT miters pass, with the same
explicit coherent-owner/mode conditions and no opaque combinational inputs.
The exact planned LUT INITs, input order and four `SINGLE_CY8` carry chains also
pass 73,728 vectors using the installed Vivado 2025.2 Unisim primitives, including
both owners, all three pairing-term combinations and word-wrap cases.

This bounded ECO proposes **71 LUTs, four CARRY8s, zero FFs**, deliberately
retaining the old now-redundant post-PC cells to avoid disturbing other routes.
Those temporary test-image counts are **not** the production RTL leaf's area
savings. Nine candidate sites are specified, but their availability must be
checked against the current checkpoint before mutation; an ancestral vacancy
catalogue alone is insufficient. Placement, routing, physical-preservation
checks, timing checks, bitstream generation and hardware replay are all pending.
The verified tests here do not establish that this change repairs Quake.

#### Local implementation checks: rejected pin-remapping attempts (Oct 8 UTC)

The first implementation (`ventium-fastpc-eco.rjTkv0`) routed the finite
75-cell/48-original-input plan, but the post-route preservation check rejected
an original LUT input's changed physical pin assignment. Native exit **1**,
resource and input-pin checks **0**; no output checkpoint or deployment.

The separately named R2 (`ventium-fastpc-eco-r2.ftHJDZ`) exported every mapping
difference before checking it. It disproved the initial narrow hypothesis of
equivalent-input coalescing alone: **21 declared target inputs** changed maps,
including high-word single inputs and moves to previously unused LUT pins.
The single-input preservation check rejected R2 too, native **1** and
resource/input-pin checks **0**. Do not label either routed-but-rejected run a
physical pass. Logical LUT INITs, old placements/locks, all 413 planned
connections and all 236,980 FF-input polarities had passed their preceding
checks; the later unrelated-route checks were **not reached**.

R3 (`ventium-fastpc-eco-r3.t47wLR`) is a fresh bounded rerun, still pending.
It temporarily locks **every input of all 32 affected old LUTs** to its original
physical assignment while routing, then restores the original lock properties.
Both all-pin literal mapping and original-cell properties must pass afterwards;
this does not waive the rejected conditions. The arithmetic plan is unchanged:
71 new LUTs, four CARRY8s, zero FFs, no clock/admission/branch-control change.
R3 input-manifest SHA-256:
`c88d0fd9dc32aad2dd42500be0ae7c94d81a3da4d431e783a647c1c7d54b38f1`.

Only one guarded Vivado family runs, with 12 GiB hard/11 GiB early-stop limits,
no swap, a 4 GiB host-memory reserve and a 900-second launcher cap. There were
no OOM events in the two closed attempts. Their four large baseline exports
were losslessly gzip-compressed after closure; every decompressed SHA-256 was
verified. Checkpoints, code and failure logs remain intact. On the board, only
the closed `ventium-warmcaller.pm9WwW/run.vhd` duplicate was removed: its hash
matched the retained original cold seed exactly, so it is recoverable by copy.
The different `ventium-word7.rIrS2H/run.vhd` was deliberately retained.

The repository's runtime mode guard passes all **7** tests; the actual FPGA
wrapper's source/profile guard passes all **19** cases, including rejected
fast-path-off overrides and invalid `cycle_mode` connections. These test
enforcement, not execution correctness. An initial generic unittest discovery
found zero tests in the script-based profile checker; the 19-case result is
from its required direct invocation against the frozen hardware build.

The deployed image remains `c2ce7e80` at 40 MHz, not repaired; neither it nor
the candidate has qualified gameplay IPC. Historical `53f129e9` remains
**0.165995778 primary/U-counter IPC**, not total U+V, from 127 qualified
intervals with gaps within cycles 8,721,490,845–19,169,282,165 at
37.499869765 MHz. The standard suite and original cold 40 MHz timedemo remain
pending; no U-only or slow-mode control is accepted as a fix.
