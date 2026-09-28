# P54 timing feasibility tools

`pair_bound.py` implements **experiment A only** in
[`docs/P54_SUB1_CPI_MASTER_PLAN_2026-09-27.md`](../../docs/P54_SUB1_CPI_MASTER_PLAN_2026-09-27.md).
It accepts one JSON object per *completed x86 instruction instance*, with all
`Insn` fields in `pair_bound.py` present. The tool rejects missing fields and
reports the maximum non-overlapping adjacent pairs on that fixed path. Its
rules are independently transcribed from Intel AP-500 (241799-001), §§5.5–5.6.
The `instance` identifier distinguishes a REP instruction from its elements;
`boundary_after` prevents pairing across an event or changed control flow.

Run the directed rule tests with `python3 -m unittest discover -s tools/p54_timing`.
No gameplay trace currently supplies all required annotations (in particular
physical data addresses and decoded per-instruction dependencies). Do not
fabricate them from retire PCs or label this optimistic bound a measured CPI.
The memory bank-conflict count is diagnostic: a conflicting pair is still legal
but V waits. Cache residence, latency, AGI, prefix decode clocks, FP timing,
branch recovery, and exact completed-instruction accounting remain required
for experiments B–D and final qualification.

`tools/state_delta_analyze.cpp` can also emit `<prefix>.fast_issue_bytes.tsv`
when passed the exact-build `fpd_layout.tsv`. Each row is an S_PIPE U/V
retire with a verified physical I-cache tag, selected way and BRAM return
buffer. `owner` distinguishes a fresh descriptor from a registered memory
owner; the latter is admitted only while its saved PC still equals the live PC.
Page-crossing byte spans are excluded; `mode16` records the code-size mode for
independent decoding. `legacy_ordinal` is the absolute callback ordinal; gaps
are expected because slow instructions, unbuffered code and other unproven
owners are excluded. `validate_fast_bytes.py <prefix>` checks those ordinals against
the analyzer's binary retire observations and independently decodes every
exported byte span with Capstone. The last registered edge may be outside the
host-callback window; it is checked against `final_registered_retire`. This
export is a provenance tool, **not** yet a complete gameplay timing-model
input. Never close ordinal gaps or treat the covered subset as representative
without measuring coverage and the omitted classes.
