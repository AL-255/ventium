# Explicit qualified QEMU reference — October 16, 2026

The unified gate now has an **opt-in, exact-identity reference profile**:
`i386-defined-x87-preexit-20261016`. This exposes the independently qualified
private reference through the real `make verify` path. It is not a replacement
of the default emulator, a new comparison mask, a timing-band relaxation, or
FPGA acceptance. The fresh gate completes with **108/108 functional PASS**,
but **nine failed cycle bands** keep its overall verdict **FAIL**.

## What is selected

[`qualified_profile.py`](qualified_profile.py) requires the exact executable,
closed build receipt, and all **11,132 source files**. A version string or an
arbitrary `QEMU` environment override is insufficient. Missing, changed, or
unqualified inputs fail closed before corpus execution. System-mode QEMU is
not selected or repaired by this user-mode profile.

| Identity | SHA-256 |
| --- | --- |
| Qualified `qemu-i386` | `998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85` |
| Canonical source closure | `a6bd62b25b25ca074cdc22de5ce1b48f0451b6efc9957b30cec71627830819b3` |
| Qualified source closure | `4093b981d0910792574afc1d69125c846cb783bbd1fe9079432ba036a71058ed` |

Closure hashes cover sorted `relative-path + NUL + sha256-hex + newline`
records. Only the root `.git`, `build`, and `build-sys` directories are excluded.
The canonical source is the pinned QEMU 8.2.2 checkout at
`11aa0b1ff115b86160c4d37e7c37e6a6b13b77ea`, including its existing local
integration changes. It is **not** represented as a clean upstream checkout.
Neither that source tree nor the original executable is overwritten.

The composition check starts from the canonical source, applies the existing
recipes in order, and reproduces the qualified source byte-for-byte. Exactly
five files differ: `linux-user/syscall.c`, `fpu/softfloat.c`,
`fpu/softfloat-parts.c.inc`, `include/fpu/softfloat-types.h`, and
`target/i386/tcg/fpu_helper.c`. There are no omitted or extra source files.

| Repair | Independent qualification and limits |
| --- | --- |
| Terminal post-state observation | [Pre-exit observer](PREEXIT_OBSERVER.md): real final state, not a fabricated/truncated trace; observer-aware [cache identity](../lib/GOLDEN_CACHE_PREEXIT.md) |
| Round increment, quotient bits, x87 environment codec and instruction C1 | [Composed C1 reference](c1_reference/README.md): 34,200 instruction cases; exact expectations and native x87 agree, old reference fails 24,254 status checks |
| FRNDINT precision and exception behavior | [FRNDINT reference](frndint/README.md): 28,612 cases, 5,472 stack/state cases and 72 adjacent controls |
| FPREM/FPREM1 precision and operand exceptions | [Sequence](remainder_sequence/README.md) and [operand](remainder_sequence/EXCEPTION_STATUS.md) tests; precision is restored for following arithmetic |
| Exact tiny-result underflow | [Underflow qualification](remainder_sequence/UNDERFLOW_STATUS.md): final executable passes 17,232 architectural cases and 7,488 sequences/216,768 records plus 96 precision-restoration controls |

Native host x87 is a defined-result cross-check, **not P54 timing evidence**.
These qualifications do not repair all QEMU x87 stack instructions. The existing
three programs with unmasked stack-related differences still require separate
resolution; their old comparison masks are unchanged. Recipe composition alone
does not qualify a newly compiled binary: a different executable hash requires
its own retained regression evidence before the selector can accept it.

## Running the explicit profile

Current retained build:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/build-underflow-r1`.

```sh
export TMPDIR=/home/yukidama/external/tmp
export PYTHONDONTWRITEBYTECODE=1
python3 verif/qemu-trace/qualified_profile.py --check-source \
  ventium-refs/07-p5-emulation-harness/build/qemu
python3 verif/qemu-trace/qualified_profile.py --select-build "$REFERENCE_BUILD"

# PRIVATE_CORE must already have its exact source/define/build qualification.
# FRESH_OUT must not exist and must be on the mounted external filesystem.
python3 verif/qemu-trace/run_qualified_profile_gate.py \
  --core "$PRIVATE_CORE" --reference "$REFERENCE_BUILD" --out "$FRESH_OUT"
```

The runner invokes the actual `make verify`, including its `issue-uv`
prerequisite. It selects the prebuilt model with `TB_BIN`; it does not replace
the canonical model. Both functional and cycle jobs select AXI, with latency 7;
functional runs use `--cycle-func`, cycle runs `--cycle`. The exact model
defines, source pins, invocations, native CPU affinities, all output and native
exit are retained. All 20 cycle streams are compared against the same model's
previous run, without editing either trace. A failed gate remains exit 1 from
the controller, with `make`'s original exit separately recorded.

The 600-second command cap runs inside the shared build scope; the detached
scope's actual RAM/tasks limits, **not the outer service's limits**, constrain
its children. Admission requires >5 GiB free external space; the live floor is
4 GiB. This run does not launch Vivado or the standard suite.

For direct use, `VTM_QEMU_PROFILE_BUILD` is the sole new gate selector. When
absent, `make verify` still selects the original reference. When present, its
validated reference enables `VTM_QEMU_GDB_PREEXIT=1`; the worker's existing
binary/observer-aware cache key prevents reuse of original-oracle goldens.
Use fresh `VERIFY_WORKDIR` and `VERIFY_CACHE_DIR` locations on external storage.
No masks, test sources, comparator, cycle plugin, clock estimates or bands are
changed by selecting the profile.

## Closed native result

Evidence root:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`;
fresh output `qualified-reference-profile-r1/gate-r1`.

The actual `make verify` runs for **388.954 seconds**, generates all 128
goldens from an empty private cache, and exits **2**. The controller correctly
exits **1**, not a passing status for partial success. Model SHA-256:
`5a2fcb865e53dc67a3f866ab1edbc8bbbc4917708e984a62d60bc8400c67f2d3`.
It is the 153-define private qualified-pair-credit build, not the current
dirty checkout and not a new FPGA image.

| Check | Result |
| --- | --- |
| Functional comparisons | **108 PASS, 0 FAIL**, 80,800 complete records |
| Architectural retire counters | U **50,668**, V **30,132**; fast-issue pair subset **30,123** |
| Cycle bands, unchanged | **10 PASS, 9 FAIL, 1 INFO** |
| All 20 RTL cycle streams versus the previous same-model run | Complete parsed records identical, including clock/pipe/pair fields |
| AXI / acceptance mode | Both job types select AXI; functional `--cycle-func`, cycle `--cycle`; all 20 cycle argv checked against debugger/trace-disabled controls |
| Source and lifecycle audit | 977 input pins rechecked, qualified QEMU source closure rechecked, exact owner terminal, detached scope reaped |

The failed kernels remain `mb_depadd`, `mb_indepadd`, `mb_faddchain`,
`mb_dmiss`, `mb_imiss`, `mb_mul`, `mb_imul2`, `mb_rmimm`, and `mb_nearbr`.
The native cycle comparisons and their original band summaries are retained.
The 108-program functional result uses the existing comparison rules; it is
not a new fully unmasked x87 stack qualification or a system-mode suite pass.

Owner `ventium-qualified-reference-gate-oct16-r1.service`, invocation
`7345a9c1ce2a491c93e918ffc50fcc06`, closes with MainPID 0. Guarded scope
`ventium-build-1000-2484693-23481.scope`, invocation
`eef601168ba54eb591112bdd43321cad`, used **4 GiB / 64 tasks**, independently
of the 2 GiB outer controller limit. Both observed native executable samples
have actual CPU0–3 affinity and belong to that scope.

The original controller's `functional_v_retired=30123` field was a reporting
mistake: it summed the S_PIPE issue-pair subsection, omitting nine V retirements
from other paths. The maintained parser now requires native total/U/pairedV
counter consistency with each complete functional trace. The original receipt
is **unchanged**; `audit.json` records the corrected **30,132** total and the
separate subset. This changes no native verdict, trace, or gameplay IPC.
Its exact original script is preserved as
`gate-r1/run_qualified_profile_gate-observed.py`, SHA-256
`dd471f4eedaf59b6bd10a970df34d1709785b3cebb9cd1e8745e6edce60799c9`.
[`audit_qualified_profile_gate.py`](audit_qualified_profile_gate.py) accepts
only that one explicit historical source alias; every other input must match.

Twelve host tests pass: five source/profile checks and seven aggregation/shell
checks, including default-reference preservation, rejected invalid profiles,
debug-mode rejection, changed cycle streams, retained failures, and the
total-versus-subset counter regression. No simulator rerun was necessary to
recount its already-recorded native counters.

## Earlier failures are preserved

The same qualified-pair-credit model previously returned native `make` exit 2:
**7 functional PASS / 101 FAIL; 10 cycle PASS / 9 FAIL / 1 INFO**. The new
selector does not relabel that run or modify its receipts. Its original
`verif/verify.sh` is archived as
`qualified-reference-profile-r1/prior-verify.sh` under the evidence root,
SHA-256 `7c65a13dc91de4bf94db923b2b91053347a6a12b5133964aa748fca8cddc282a`.
Historical receipts pin that historical script. Rechecking them against the
now-edited working script must report drift; an explicit historical-source
alias or a fresh proof is required, not a silently rewritten receipt.

The old cycle traces show real pairing: `mb_indepadd` retires 1,633 V
instructions out of 3,268, and 1,612 inter-retirement deltas are one clock.
Its 19 cold-fetch gaps are 70 clocks each, while the legacy plugin is configured
for eight-clock misses. `mb_depadd` similarly has 3,211 one-clock deltas and
19 seventy-clock gaps. The [AXI backend audit](../../docs/UV_FAST_VERIFY_BACKEND_2026-10-08.md)
already documents why the hardware backend differs from the direct-memory
bands. These observations explain a major contribution to the failed bands;
they neither account for every failing kernel nor waive any failure. No hot
window, reduced miss penalty, or U-only control replaces the full gate.

## Acceptance still open

This is reference/verification integration, not an IPC improvement. The paired
credit candidate still needs timing evaluation and full acceptance: duration-
valid CoreMark performance, both correctness seeds, Win95 desktop/UI, complete
Quake timedemo, and current-build physical FPGA verification at the required
clock in UV fast-pipe mode. Current candidate gameplay IPC is unmeasured.

Last verified simulation gameplay baseline: **0.497040387 total U+V IPC**,
model `b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`,
cycles **1,100,065,247–2,100,065,247** (U 384,240,079; V 112,800,308).
It predates this candidate and is neither FPGA IPC nor a completed timedemo.
