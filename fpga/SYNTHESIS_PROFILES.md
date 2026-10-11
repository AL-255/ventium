# RK synthesis profiles

`create_project_3mhz_wrapper.tcl` accepts `VEN_FPGA_BUILD_PROFILE`:

| Profile | Synthesis | Implementation |
| --- | --- | --- |
| `legacy` (default) | `AreaOptimized_high`, timing-driven | Historical upstream choices |
| `balanced` | `Default`, timing-driven | Spread placement, default routing, no post-route physical optimization |
| `logic_only` (diagnostic) | `Default -no_timing_driven` | Same as `balanced` |

`logic_only` changes exactly one project-run property. It does **not** change
RTL, U/V or fast-pipe defines, clock constraints, cache geometry, run fan-out,
or timing acceptance. It is opt-in; the existing profiles retain their defaults.
Always use `run_vivado_exclusive.sh` and the shared resource guard. A synthesis
completion does not authorize deployment or establish timing closure.

Why investigate this: the October 9–10 full performance synthesis completed
constraint processing at 12m40s / 6,436 MB reported peak, but timing optimization
finished at 1h50m26s / 18,805 MB peak. It then entered technology mapping and
was stopped by the host's 2 GiB memory-reserve watchdog. This was **not** a
completed synthesis or an OOM kill. Source/log/stop receipts remain in
`external/tmp/ventium-performance-synth40.t5wzn9jz/`. The measured phase cost,
not a guess about routing congestion, motivates this separate experiment.

AMD documents that this option disables timing-driven synthesis and can reduce
runtime, but synthesis then ignores timing as an optimization objective.
The later full-chip diagnostic **did complete**, but neither disabling this
objective nor completing synthesis establishes timing closure. Routed setup/hold,
frequency and resource checks remain required.
See [Vivado 2025.2 `synth_design`](https://docs.amd.com/r/2025.2-English/ug835-vivado-tcl-commands/synth_design).

## Retained full-chip evidence

`external/tmp/ventium-sfetch16-logic-synth.oLSgt6W7/closed.json` records native
exit 0 on October 10 in **1,106.82 seconds**, unchanged inputs and no resource
stop/controller failure. Peak scope use was **8 GiB RAM + 702,697,472 bytes
swap**. Its native synthesis log confirms `synth_design completed successfully`.
The receipt SHA-256 is
`a527c6feb2ec4148b8063630f595fe3c23cd397158b8c5748b997c2763caca99`.
The subsequent independent project/checkpoint audit and resource results are
documented in [PERFORMANCE_EXPORT.md](PERFORMANCE_EXPORT.md).

By comparison, the earlier timing-driven controller closed natively with 143
after **6,688.66 seconds** and a `host memory/swap reserve` stop. Its scope peaks
were **21,091,545,088 bytes RAM + 8,589,918,208 bytes swap**. This differs from
the main Vivado process's reported 18,805 MB peak at the timing phase; neither
metric should be substituted for the other. No completed timing-driven Fmax
exists for that attempt.

These runs have different source revisions and resource caps. They establish
that the diagnostic flow can finish within the smaller budget, **not a controlled
percentage speed/memory improvement attributable solely to the profile**. The
current structural timing comparisons retain `logic_only` on both sides so
RTL changes remain attributable. A later timing-driven experiment needs a fresh
source-matched run and its own RAM/swap admission checks; do not silently switch
profiles in a live comparison or lower reserves to force one through.

The current requirement is **at least 40 MHz synthesized Fmax**, preserving UV
and fast pipes. A 40 MHz input constraint is not evidence that this requirement
has been met. See [MC_READ_COMMIT.md](MC_READ_COMMIT.md) for the active candidate.

## Checks

`test_synth_profiles.py FROZEN_EXPORT` checks all three legal profiles, rejects
invalid values and compares the expanded scripts byte-for-byte after removing
the single diagnostic property. `test_uv_fast_profile.py FROZEN_EXPORT` retains
the U/V/fast-pipe and posted-bridge source guards.

`probe_synth_profile.tcl` builds a tiny registered adder through the **actual
wrapper-generated project-run launch**, on the same ZU15EG part. Run it through
the exclusive launcher with a fresh external output directory, one worker,
bounded memory/swap and a timeout. Arguments are `WRAPPER FROZEN_EXPORT OUTPUT`.
It checks both native generated synthesis commands, successful run status and
the unchanged **25 ns / 40 MHz** clock. It is not a processor synthesis.

The October 10 native probe completed both profiles in **104.82 seconds**, exit0,
stable source pins and no remaining Vivado process. The enclosing scope recorded
4 GiB peak memory and about 1,010 MiB peak swap, within its 4 GiB / 1 GiB caps.
Evidence: `external/tmp/ventium-synth-logic-probe.5QHLAEUj/`, controller invocation
`cd622b705f474e8aaec82468b35d6e0e`. An earlier preflight rejected a symlink-versus-
canonical-path comparison before launching Vivado; that failed script is retained.

Do not restart the full build until its disk/RAM/swap admission checks pass.
The diagnostic profile is not permission to lower reserves, kill user apps,
relax constraints, or treat old checkpoints as a new result.
