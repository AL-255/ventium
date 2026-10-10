# Shared prefix-successor fetch: exact FPGA export

**UNQUALIFIED** hardware source, not a deployed bitstream. This successor
preserves UV, system/relocated fast pipeline, fast loads/stores and all ten
performance backports. No additional memory port, cache state or pipeline cycle.
The sixteen successor-byte lookups share two line probes, retaining cache-way
and bypass priority, returned identities, collision behavior and stale bytes.

Latest verified gameplay is parent `958f7ec4`: **0.50530999** U+V event IPC at
clocks **3,900,048,811–4,000,048,811**, all 28 consecutive windows averaging
**0.4862721782**. REP events are not exact P54 macroinstructions. New model
`343f0ccd` is gameplay-unmeasured and cannot inherit the parent's acceptance.

## Source identity

Export: `/home/yukidama/external/tmp/ventium-ic-prefix-fpga40.PVEqvUFL`.
Manifest: `122eafbd1a0e54c405c5fc423d5d84b6a1cb63c3aa4a206a9425f390e8318bdd`.
Native model: `343f0ccdddfcdecc0f41b46944c7b48aa4456b5ae29da1d60db05e7bffe10951`,
source root `ventium-ic-prefix-soc.ApbJoeMH` on external scratch.

189 payloads, 148 hardware defines (146 native plus `SYNTHESIS` / `VTM_NO_DPI`).
Against [the immediate parent](IC_BUFFERED_EXPORT.md), only `core.sv` changes,
`core_ic_prefix_span.svh` is added and `VEN_IC_PREFIX_SPAN` is inserted into the
ordered profile. All 169 non-wrapper compiled payloads match the native source;
the unchanged hardware top's simulation transport projection is checked.
Closure: 117 filelist units / 48 include edges. Constraints remain **40 MHz
core / 100 MHz PL**; full P5 L1s, 256 KiB L2, 16 posted DDR slots.

## Qualification evidence

- **85 freezer tests**, **35 independent real-Tcl admission checks**, and
  **three entire-native-command parser tests** pass. The auditor compares the
  actual `Vsystem__verFiles.dat` command to the pinned invocation, not a filtered
  define-count approximation. Arbitrary RTL aliases/profile substitutions fail.
- The freezer enumerates 20 permitted historical script aliases; 18 occur in
  this model's proof closure. No arbitrary aliases or inherited test passes.
  Initial refused preflights and auditor failures remain recorded separately.
- Strict hardware CPU lint closes native 0, 2.505 seconds, stable source pins,
  six fatal structural classes. Evidence `ventium-ic-prefix-hw-lint.S9391R5Q`,
  supervisor `7406c61c57584934a29021b90c9e0247`.
  This is not whole-platform/vendor-IP lint; 98 inherited platform warnings remain.
- Both short CoreMark seeds close native 0, original five CRCs and unchanged
  **4,767,218 / 4,753,406 ticks**. These are duration-invalid diagnostics, not
  qualified scores. Own duration-valid seeds, Win95 and Quake cold boots are
  running; [exact services and bounds](../docs/CACHE_BACKED_TARGETS_2026-10-10.md).
- [The narrow RTL evidence](../docs/FPGA_FETCH_CONGESTION_2026-10-10.md) includes
  427,296 four-state comparisons, fixed-address updates, three specifically
  rejected faulty variants and 768 identical full cycle-record A/B lists across
  384 cold paged fixtures. The isolated gather uses 27,949 → 4,640 CLB LUTs;
  **83.40% local reduction is not a whole-chip prediction**.

Reproduce host/source checks with canonical paths and a fresh output:

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B -m unittest discover \
  -s fpga -p 'test_freeze*py'
TMPDIR=/home/yukidama/external/tmp python3 -B fpga/test_ic_prefix_board_profile.py \
  PARENT SIM EXPORT
TMPDIR=/home/yukidama/external/tmp python3 -B fpga/test_ic_prefix_native_command.py
```

The freezer's `--help` lists required build-receipt hashes. It deliberately
rejects arbitrary similarly named models. Historical evidence is ancestry only.

## Whole-design synthesis and remaining gates

`ventium-ic-prefix-full-synth.7G1TINWD` started at **10:44 UTC October 10**,
controller `28bdb208060943198f3c835519d1c93c`. Single Vivado family, 8 GiB RAM /
6 GiB swap, 30-minute native cap, external scratch and monitored reserves.
Same logic-only mapper and clock constraints as the **220,699-LUT immediate
parent**. This comparison isolates prefix sharing; comparing to the much older
190,864-LUT profile mixes in performance backports. No automatic route/deploy.

Generic differential verification remains **red**, unchanged discrepancies and
cycle bands retained. The exact-source functional recheck with the requalified
live terminal-state observer gives **107/108 comparisons passing**, retaining
the known `tx_fprem` C1 failure. No comparison masks or trace records changed;
the proposed FP correctness repairs are not in this source. See the linked
target log for the failed subgate's complete evidence.
Duration-valid new CoreMark, Win95 desktop, full original
DOS demo1 (969 frames), full-design area, effective project clocks, routed
frequency and silicon acceptance remain open. A bare synthesis DCP omits project
clocks; clock admission must use `open_project` / `open_run synth_1`, not invent
new clocks to hide the inherited generated-PS-XDC warning.
