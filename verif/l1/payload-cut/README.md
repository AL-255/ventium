# ACK-equivalent primary-window payload experiment

**Not enabled in production; not Quake/FPGA acceptance.** Preserve UV dual issue
and all fast paths. This only factors a data selector; it does not change ACK,
permission checks, cache tags/capacity, state, pairing or transaction timing.

The registered primary window had two byte selectors: the live offset for
`window_reuse`, otherwise the captured offset. On an acknowledged `rd_match`
read those offsets are equal by the exact request-address owner check. Therefore
one live-offset selector is sufficient for both cases. `early_match` and reuse
are mutually exclusive. Bypass retains its saved owner/offset; the separate
hit-stream override retains its saved offset. **Shadow qualification is not
weakened**; no current tag/hit check has been removed.

`primary-payload.patch` applies to the committed response-owner repair
`0f12b208`, source SHA-256
`e24b9140f6c1c36dbc4478c88e09596787fcf40388b96197c90ad0a3bc418572`.
It must not be applied to the earlier buggy `early_armed` payload mux. Exact
patch dry-run rejects that old source. The patched source is
`aba87b60f05c0ee5ee6d994d5d62fc8367440b11f80c419799727c35538b743e`.
The runner requires this exact reviewed source; a later delta needs a deliberate
review/update, not a silently changed baseline.

The patch includes a simulation-only assertion comparing the original repaired
payload expression with the simplified one on **every acknowledged read**.
`primary_mux.smt2` proves the Boolean/bit-vector lemma under the actual selector
invariants (`unsat`), then drops exact registered ownership and requires a
counterexample (`sat`). This is not a formal proof of the entire cache FSM.

## Replay

In a fresh directory under `/home/yukidama/external/tmp`, prepare
`candidate/rtl/mem/ven_l1d.sv` by copying the pinned repaired source and applying
the patch with `patch --batch --fuzz=0 -p1 -d /prepared/candidate`.
Place the combined simulator's exact 110-definition command line at
`exact110.defines.args.txt` (107 hardware-profile simulator switches plus
FE_PIPE/MULTI/PERM). Do not add SYNTHESIS or disable assertions.

```sh
bash verif/l1/payload-cut/run-leaves.sh --work-dir /absolute/prepared/directory
```

Requires Verilator, C++ compiler and Z3. Eight builds run at four compiler jobs
each in the bounded 32-job scope. Tests cover primary/two-window reuse,
unrelated-store retention, packed/banked data, stream backpressure, narrow/wide
loads, snoop/flush races and the exact full-profile critical-owner collision.
Ten native scenarios must pass, with unchanged inputs and recorded binaries.
The full-profile leaf ties pair producer ports inactive; it is not by itself a
whole-core U/V test. The separate full-core regressions require real paired V
retirements and full QEMU architectural agreement.

Results, physical comparison, build identities and unresolved acceptance gates:
[audit](../../../docs/UV_FAST_L1_PAYLOAD_2026-10-08.md).

For the isolated physical replay, copy `physical/*`, the pinned control and
patched L1 as `control.sv`/`repair.sv`, both `ven_p54_bank_arb.sv` and
`ven_p54_hit_return.sv`, and `exact110.defines.args.txt` into a fresh external
scratch directory. Run its `run_synth.py`. It uses the exclusive Vivado guard,
8 GiB/no swap, one worker and a 600-second bound. This models a cache-only
25 ns port budget with zero external delays, not CPU timing. Do not launch the
bounded generic verification envelope while it is queued behind this scope;
the queue would consume most of that envelope before verification starts.
