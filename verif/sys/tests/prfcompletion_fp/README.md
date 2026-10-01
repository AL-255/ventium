# x87 successful-completion RF probes

Four standalone CPL0 protected32 cases restore RF1 using IRETD entered with
RF0, execute FNINIT, FLD32, FNSTCW or FNSTENV28, then capture the full #UD
frame. FNSTCW/FNSTENV read back CW037F and, for FNSTENV, SW0/TAGFFFF from
destinations initialized to different sentinels. These are RF/completion and
selected store-field witnesses, not full x87 datapath/environment correctness.
The complete compared trace is integer/system (`x87=false`), with RF included.

```sh
TMPDIR=/absolute/root-filesystem/scratch \
  bash verif/sys/tests/prfcompletion_fp/run.sh \
  --tb /absolute/ignored-model-dir/tb_ventium \
  --out /absolute/ignored-model-dir/fresh-run
```

The runner uses the same strict native133/free-QEMU133/closed-process/full
`func --all` contract as sibling `prfcompletion`, preflights ports21360–21363,
and adds a 50-second command budget per case. It never rebuilds the DUT or
changes flags/records/guest state. The output path and filesystem rules are
the same as the sibling suite; the aggregate/outer limits are500/520 seconds.

October1 legacy-FP a48f passes all four; closed summary SHA256
`8936df7c6c5400f6adedea3723648998a3b04d04bf4ee5361a05aa39a77c403c`.
Shared-FP profile qualification is separate. Faults, partial beats, events,
debug traps, task/RSM exemptions and complete standard-suite acceptance remain
outside these fixtures. This standalone multi-image suite is not registered
with the generic single-image system runner.
