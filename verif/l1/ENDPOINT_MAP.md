# Parallel endpoint-map decode — October 13

Status: **implemented in an isolated full-core candidate and regression-checked;
no timing, full-PC, standard-suite or FPGA acceptance yet**. The canonical gate
remains red. This does not meet the 40 MHz requirement by itself.

## Change

The [PRIME-REG timing report](PRIME_REG_FLAGS.md) identifies a 99-level
`q_pc` → memory-owner path passing through the last-byte address addition,
cache-map decode, paired-store admission and ACK. Its synthesized/unplaced
estimate is **35.023816195 MHz**, not 40 MHz sign-off.

`prepare_endpoint_map.py` changes only `rtl/mem/ventium_l1_axi.sv` on top of the
compiled SMSW + PRIME-REG composition. The cache map has no boundary within a
32-byte line, and a producer's extent is at most four bytes. The replacement:

- Decodes the current and next line in parallel, using the existing two map
  instances. A six-bit low-address/extent sum selects the final-byte result.
- Precomputes complete endpoint routing permission when `ADDR_MASK` covers
  whole lines. For arbitrary masks that split a line, it retains the original
  byte-exact PCI aperture check.
- Preserves `core_d_last` exactly, including zero-strobe read fallback,
  zero-strobe writes and 32-bit wraparound. Arbitrary SMBASE comparisons retain
  this original full byte address.
- Changes no cache capacity, state, request, ACK, permission, fault, pairing,
  clock, mode or latency rule. Simulation assertions compare the original
  final-byte map and routing expressions continuously after reset.

The isolated parent/candidate source sets contain the same **195 files** and
**152 UV-fast definitions**. Exactly one file differs. Root RTL and unrelated
worktree changes were not overwritten. Source/hash drift and reapplication are
rejected; three recipe tests pass.

## Closed verification

| Check | Result | Scope |
| --- | --- | --- |
| Exact-source map miter | 720,896 vectors, 11,534,336 comparisons | Both snapshot-map parameter values × eight physical address masks; dynamic chipset configuration; all strobe/direction combinations at every map boundary; random inputs |
| Coverage witnesses | 9,088 wraps; 171,531 line crossings; 22,581 zero-strobe reads | Counts are input vectors, before the 16-profile multiplier |
| Negative variants | All three rejected | Lost tail map, lost subline-mask fallback, lost legacy read extent |
| Symbolic arithmetic | Two UNSAT equivalence queries; three SAT witnesses | All address/strobe/direction values and arbitrary masks under the stated line-mask premise; **not** a whole-RTL sequential proof |
| Full-core build | Native exit 0, 20.46 s | Unchanged UV-fast profile, assertions, 32 compile jobs, private host object/header, 10/2 GiB RAM/swap cap |
| Six-harness route/extent/CD gate | Parent and candidate pass, 13.36 s combined | Actual L1/AXI/CDC with the existing memory-only gate profile; VGA, PAM, holes, TOM, BIOS shadow and RAM-window boundaries |
| Initial SMSW differential | 88 cases / 6,556 records pass | Real/protected mode, ordinary-store controls, prefixes and crossing stores |
| CPL3/V86 differential | 60 cases / 11,250 records pass | Unmodified QEMU system-state comparison |
| Fault differential | 25 paging passes; 20 reference disagreements | The LOCK/segment cases still satisfy RTL Intel-spec self-checks but differ from pinned QEMU; full fault driver exits **1**, not a pass |
| Canonical `make verify` | **7 PASS / 101 FAIL**, native make exit **2**, 404.29 s | No mask, golden, comparator or band change; all 20 cycle traces exactly match the parent |
| Exact-input canonical replay | 108 cases / 80,800 records identical, 77.03 s | Parent/candidate/original-candidate complete records agree; this **does not** make the QEMU gate green |

The canonical shell forces one worker despite the controller requesting four.
The focused CPL3/V86 and fault tests run parallel workers with explicitly
checked CPU affinity. The 173 directed differential passes are executions of
existing fixtures, not newly invented independent cases.

`audit_endpoint_map.py` independently checks source/artifact hashes, terminal
owner invocations and native outcomes. It re-compares all **193 directed cases /
22,891 records** against the composed parent, plus every canonical replay and
cycle record. Its successful audit retains both red-gate statuses explicitly.
All run owners are terminal; no Vivado run or FPGA programming occurred.

Two launch errors are retained separately: the first leaf service omitted the
build guard's required `--` and exited before starting any test; the first
fault service supplied 16 CPUs where the existing driver requires eight and
exited before creating its output. Corrected launches did not alter a guard or
fixture. Neither refusal is counted as a DUT result.

## Identity and evidence

Root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

- `endpoint-map-core-r1/obj/tb_ventium`:
  `164e17003b2ec03cd7b92cc8bbe89b576e5f440becc4204e37368e075c87e8df`.
- Changed seam source:
  `4e923bc360a388c113c0ee9936e5f39e90411707aeb2c59806683398e3a610ec`.
- Parent model (`smsw-prime-reg-core-r1`):
  `42bd14c86eff5e33d98753cd07d34bf1340e804989daec237e42fd499565cfa5`.
- `endpoint-map-audit-r1.json`:
  `0165e78d169a5a582fc1878ee0b97b414b40900000f2ab32b3e7e5adff70f5b5`.
- Leaf, route, SMSW, privilege, fault and replay evidence uses the corresponding
  `endpoint-map-*-r1` directories. The core contains `build-closed.json`,
  `verify-closed.json`, `generic.log`, complete traces and original commands.

Closed leaf compiler products (146 files, 662,616,986 bytes) were losslessly
archived to 84,534,901 bytes after byte comparison. Sources, headers, binaries,
logs and every pinned artifact remain expanded. Recovery commands and member
hashes are in `endpoint-map-leaf-r1/compiler-archive.json`. The route driver
similarly retains per-build recoverable compiler archives.

## Next required work

Transfer the exact four-file delta from the SMSW-free PRIME-REG PC/FPGA source
set (three SMSW files plus this seam) into a source-matched PC build and freeze.
Then measure whole-design timing/area under unchanged 40/100 MHz constraints
and resource guards. **No gain is attributed to this change until measured.**
Continue resolving the canonical reference/RTL failures without weakening the
gate; complete the standard suite and physical UV-fast Win95/Quake validation.
The installed old Doom image still faults on SMSW; new Doom gameplay/FPS needs
a repaired, qualified bitstream. The repair/retry latency matrix and broader
fault/event corners are not inherited from the parent merely by matching these
directed traces.

Candidate gameplay IPC is **unmeasured**. Older verified **simulation** baseline:
**0.51030715 total U+V IPC**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not FPGA/Doom
IPC. The new composition has no Fmax measurement; 35.023816195 MHz belongs to
the earlier SMSW-free PRIME-REG candidate.
