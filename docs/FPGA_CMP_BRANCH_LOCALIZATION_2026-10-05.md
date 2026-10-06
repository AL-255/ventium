# FPGA memory-CMP/conditional-branch localization — 2026-10-05 UTC

The requested **40MHz** production Quake timedemo remains **pending**.
A complete15fps recording of a separate37.5MHz cold timedemo is now retrieved
and verified, documented below. These are private cold diagnostics, not patched production Quake,
save-state repairs, or acceptance substitutes. The original control runs did
not change the installed FPGA image, clock, RTL, production BIOS or disk.
On October6 the preserved debug-only observer image was deployed, as recorded
below; it does not implement a processor fix. Production BIOS/disk and RTL
remain unchanged by this investigation.

Current verified active-timedemo IPC: **0.165995778**, retirement-observer image
`53f129e9`, measured **37.499869764MHz**,127 qualified intervals spanning cycles
**8,721,490,845–19,169,282,165**, demo frames37–898. This is the closed R4
aggregate with gaps between qualified groups, not an every-cycle full-demo
score or40MHz qualification. The earlier closed R3 aggregate is below.
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
