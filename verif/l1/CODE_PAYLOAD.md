# Saved instruction payload selection — October 10

**Private, default-off timing experiment; not deployment acceptance.** Latest
verified gameplay is **0.49971398 U+V retirement-event IPC** on `bfb867f7`,
clocks **4,100,065,237–4,200,065,237**. All 30 fixed-start consecutive windows
average **0.496605827**. This predates the unmeasured FP-corrected parent and
this cache-selector candidate; it is not an exact P54 macroinstruction IPC.

## Why this selector

The preceding full-SoC high-word candidate's closed unplaced timing estimate
is **21.362 MHz**, not 40 MHz sign-off. Its 160-level EIP-to-SRT-enable path
still passes through younger-address/lookahead qualification and the current
memory-data cone. That report is evidence for investigating a logic dependency,
not proof that this particular edit will improve routed timing.

`code_word_reuse` combines request, code-buffer identity, fill/tag lookup,
lookahead and coherence qualifications. It both grants ACK and selects already
registered instruction bytes. `prepare_code_payload.py` adds default-off
`VEN_L1D_CODE_PAYLOAD_SELECT` to separate these two responsibilities:

- ACK, capture, tag/word validity, SRAM ports, cache states and all sequential
  assignments are unchanged.
- Bypass and critical-word data retain priority; hit-stream still overrides.
- For the remaining consumed code read, an exact primary owner (`rd_match`)
  selects its saved dword; otherwise the code staging line supplies the bytes.
- The existing full payload equivalence assertion remains. New assertions
  reject unowned code selection and unequal simultaneous primary/code owners.

The new selector is `code_access && !rd_match`; it contains no `mc_lookup_next`
or younger tag-hit input. No extra register, latency stage or duplicated data
array is introduced. This is **not** permission to acknowledge invalid bytes.
Unsupported code-buffer/response configurations fail elaboration explicitly.

## Closed leaf evidence

`run_code_payload.py` extends the existing full-profile public-port fixture;
it neither writes DUT state nor fabricates hits. New traffic covers all eight
critical-word starts, both legal instruction-fetch strobe forms, partially
returned code words, complete instruction staging lines, intervening data
reads, noncacheable reads, coherent stores, DMA snoops and flush edges.

Root: `ventium-code-payload.AHGnIXe1`. All five builds complete with the six
structural-warning classes fatal. In **47.49 seconds**, unchanged control,
flag-off and flag-on variants all close native 0 and have identical complete
clock-by-clock interface observations, SHA-256
`2e8c52ab688aa7485f4b152e890e03768031b1adb34060181eb2dc3cce40694d`.
The original 150 chain acceptances, roughly 68k coherent-store checks,
15k store-warming checks and high-window cases remain in the fixture.

Each positive variant exercises **368 new reads**, **256 code-word reuse
responses**, **96 partial-fill reuse responses** and **80 critical responses**.
Deliberately selecting a wrong word or an unrelated code owner produces the
required assertion failure, native 1, in separate retained builds.
`audit.json` independently rechecks the actual closed unit invocation,
17 source pins, all native binaries and all compressed observation hashes.
Controller memory usage is not the sibling compiler-scope working set.

Coverage limitation: **zero code `rd_match` and zero duplicate code/primary
owners were observed**. The host truth table does not prove their sequential
byte-equality invariant. The assertions and this coverage gap remain explicit;
do not claim exhaustive ownership proof from the positive leaf runs.

Three recipe/ownership host tests and two corpus-adapter tests pass. The first
source transform correctly refused an ambiguous `!code_access` anchor; its
guard now includes the exact primary/shadow reuse context.

## Directed processor checks closed; canonical gate remains red

`run_code_payload_core.py` preserves the existing cold, paged/relocated FP
and integer corpora, QEMU comparison, actual UV/fast/AXI witnesses, native
closure rules and **complete** cycle-record equality. The private candidate
root is `ventium-code-payload-core.pM2bCCBu`, derived from FP-corrected
`e8253e84`; only `rtl/mem/ven_l1d.sv` and the one opt-in define change.
Model SHA-256 is
`1139570bdf6ef48967e0fdf73e88e9c75cf3c0d683c67cca55d374e26c01b9d3`.
The native build closes in 19.21 seconds, using its own C++ object and matching
generated header. The directed controller then closes **2,656 full QEMU
architectural comparisons** and **1,328 identical complete cycle-record pairs**:
1,536 FP, 1,024 integer and 96 extra FP-boundary comparisons. Coverage retains
cold reset, paging, both relocation choices, all 32 instruction offsets, AXI
latencies 0/7 and FP operand offsets 0, 1, 24, 25, 29 and 4093. Actual V
retirements are required; illegal high-word boundary responses remain rejected.
All directed children are reaped and source pins remain stable. Evidence:
`verification/micro-closed.json`, the eight per-corpus native closures and
their unchanged/adapted driver source pins.

At **18:37 UTC**, the unchanged canonical gate closes native **2 / FAIL**:
7/108 functional programs pass; 12/19 scored cycle checks fail. All **20
complete canonical cycle-record streams are identical** to the FP-corrected
parent. `verification/audit.json` independently checks the actual closed unit
invocation, 5,390 source pins, one-file/one-define delta, all 1,328 directed
cycle-stream pairs and 2,656 equivalent functional-comparison logs. It also
checks the **5,312 actual RTL native exits**: each is the fixture's deliberate
`isa-debug-exit` status 133, with the matching stop footer, zero delivered
faults and zero I/O desynchronizations—not an accepted timeout or SIGTRAP.
A directed pass and unchanged cycles do not supersede the red gate.

The parent's canonical gate is **red**. No comparator mask, golden, cycle band,
guest workload, debugger mode or pairing behavior was changed for this
experiment. Full-suite, gameplay, synthesis/routing and board qualification
are not inherited from a parent and are not yet available.

## Recoverable compiler cleanup

After native closure, the ten leaf precompiled headers were losslessly
archived, compared against their originals, and then unlinked, recovering
**724,847,785 bytes**. Archive SHA-256:
`1a1ee5b29c3c1ea22fa6f1463dca2486ee373e5e44779343dcff32f85fb778db`.
The same narrow procedure on the closed FP-bundle, FST-range and full-PC FP
builds recovered another 488,166,777 bytes: **1,213,014,562 bytes total**.
Each root has `closed-pch-manifest.json`, a verified archive and an exact
restore command. Sources, native executables, headers, ordinary objects,
logs, media and test results were preserved; source/model hashes were checked
again afterwards. No active build or Vivado process was removed.
