# P54 timing feasibility tools

`pair_bound.py` implements **experiment A only** in
[`docs/P54_SUB1_CPI_MASTER_PLAN_2026-09-27.md`](../../docs/P54_SUB1_CPI_MASTER_PLAN_2026-09-27.md).
It accepts one JSON object per *completed x86 instruction instance*, with all
required `Insn` fields in `pair_bound.py` present (`data_bank` is optional). The tool rejects missing required fields and
reports the maximum non-overlapping adjacent pairs on that fixed path. Its
rules are independently transcribed from Intel AP-500 (241799-001), §§5.5–5.6.
The `instance` identifier distinguishes a REP instruction from its elements;
`boundary_after` prevents pairing across an event or changed control flow.

Run the directed rule tests with `python3 -m unittest discover -s tools/p54_timing`.
No gameplay trace currently supplies all required annotations (in particular
complete data addresses and decoded per-instruction dependencies). Do not
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

`analyze_fast.py <prefix>.fast_issue_bytes.tsv --legacy-retire-events N`
independently decodes those verified spans with Capstone, maps their explicit
and implicit GPR/flag uses to the AP-500 pair classes, and runs the adjacent
matching bound only within contiguous verified ordinals. Control transfers,
PC discontinuities and ordinal gaps terminate a chain. Unrecognized forms are
nonpairable in this diagnostic. Full *data* physical addresses are not yet
available, but the output
can now use `data_bank` for *explicit integer memory operands*: the exporter
reconstructs the captured linear EA, whose bits 4:2 equal the P54 physical
D-cache bank select under 4 KiB paging. Stack/FP and 16-bit addressing remain
unknown. A bank value is not a proof of full physical address, cache hit,
access width, or service latency. The output
also breaks the selected matching into reg/reg, reg/mem, mem/reg and mem/mem
classes. Ties select one matching, so the class mix is a diagnostic, not a
unique property of the instruction stream. Unobserved events whose handler
returns before the next retire may remain invisible at a sequential PC edge.
Its JSON labels explicitly say `is_full_gameplay_bound: false` and
`is_cycle_forecast: false`. It cannot establish CPI < 1 or replace the required
complete instruction-instance trace and realistic timing scheduler.

The analyzer additionally writes `<prefix>.slow_candidate_bytes.tsv` from
slow-path `q_pc/q_len/ibuf` owners. These are **candidates**: some FPU and
microsequence states retain a stale `q_len` or buffer. Run
`merge_verified.py <prefix>` to reject any candidate lacking a matching
retire-observation PC or an exact one-instruction Capstone decode. It writes
`<prefix>.verified_issue_bytes.tsv` in ordinal order and reports every reject
reason. This improves coverage but still does not establish that every byte
owner is semantically identical to a separate architectural trace. REP
callbacks remain unnormalized, asynchronous FP completion is unaccounted, and
unobserved interrupts or code mutation still require independent checks.
