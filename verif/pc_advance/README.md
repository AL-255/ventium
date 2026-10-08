# Integer fast-PC advance regression

This checks the arithmetic actually marked `PC_ADVANCE_ARITH_BEGIN/END` in
`rtl/core/core_fastpath.svh`. It does **not** substitute for whole-core
UV+fast-pipe tests or FPGA acceptance.

```sh
export TMPDIR=/home/yukidama/external/tmp
task_run=$(mktemp -d "$TMPDIR/ventium-pc-advance.XXXXXX")
python3 -B verif/pc_advance/run_gate.py --out "$task_run/result"
```

Requires `iverilog`, `vvp` and `z3`. Output is exclusively in the fresh supplied
directory. The gate extracts the production expressions, checks their widths
and binds the SMT model to the normalized expression hash. If the expression
changes, re-audit the SMT mapping before updating that hash.

Checks:

- 73,728 simulation vectors against the previous expression: all 4-bit length
  codes, both pairing decisions and code widths, carry/wrap boundaries and
  deterministic random PCs. Zero lengths strengthen the arithmetic check;
  admission of actual instructions is outside this leaf.
- Nonvacuous full-domain 32-bit SMT equivalence, including 5-bit length-sum
  overflow above 15 and 16-bit IP wrap.
- The observed hardware failure's no-redirect arithmetic witness:
  `0x14562 + 3 + 2 = 0x14567`, never `0x14563`.

The implementation computes U-only and paired advances independently and
selects **after** the wide adders. It does not restrict pairing, add a cycle,
alter flags, or change the separate V-branch redirect expression. In particular,
that redirect retains its intermediate U-width wrap; do not replace it with the
unconditional paired sum without proving mixed-width semantics.

See [the FPGA localization report](../../docs/FPGA_CMP_BRANCH_LOCALIZATION_2026-10-05.md)
for mapped leaf counts, hardware-profile integration results and remaining
acceptance requirements. Area improvements in a separately synthesized leaf
are not whole-core area, clock-frequency or gameplay-IPC results.
