# Software-RF retention and completion

These seven standalone CPL0 protected-mode cases compare complete integer and
system traces against pinned Pentium QEMU, including RF. They cover RF0/RF1
first-instruction #UD, RF1 #DE, successful MOV, STC, POPFD and memory BTS.
RF is restored by IRETD entered with RF0; entering IRETD with RF1 is not covered.
STC/BTS check that consuming RF preserves the newly produced CF; POPFD checks
that it preserves a whole-flags replacement. BTS uses an already-set bit, so
that case does not independently prove a changed memory value was written.

Use an independently built simulator; this runner never rebuilds RTL:

```sh
TMPDIR=/absolute/root-filesystem/scratch \
  bash verif/sys/tests/prfcompletion/run.sh \
  --tb /absolute/ignored-model-dir/tb_ventium \
  --out /absolute/ignored-model-dir/fresh-run
```

The output must be a fresh, owned, nonsymlink path inside a repository
`obj_dir*` directory or repository `tmp`. Check the filesystem first: `tmp`
can point to the full external disk. Guest assembly uses one job. The runner
requires normal inherited build-scope limits, preflights ports21340–21346,
records before/after model and fixture hashes, and caps the aggregate run at
500 seconds (520-second outer guard).

PASS requires actual native and separate free-running QEMU exits133, normal
native I/O/retirement footers, uncapped contiguous traces, exact frame/PC/marker
witnesses, unchanged pins, closed process groups and full `func --all`
equivalence. No RF mask, trace filter, snapshot or model-state edit is used.
UD2 bypasses the canonical fault logger; its exact handler and saved frame are
checked instead. #DE requires the canonical vector0/error0 fault record.

This is not the standard suite or an automatically registered generic
`run-sys-golden.sh` gate. It does not qualify automatic fault RF setting,
faulting memory/REP phases, asynchronous events, HLT, task/RSM transfers or
FP completion. See sibling `prfcompletion_fp` for focused FP-completion cases.

October1 a48f passes all seven comparisons (59/59/59/60/60/61/62 records),
with closed summary SHA256
`2e4a1371f8aa4cad88964493026d665eac1c2b9dbd15422376a8dcb564e1110e`.
That is a directed checkpoint, not RF-general or whole-suite qualification.
