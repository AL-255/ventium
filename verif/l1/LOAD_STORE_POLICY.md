# Owned U load + policy-qualified V store

`tb_l1d_load_store_policy.sv` exercises the production `ven_l1d` with
`VEN_P54_LOAD_STORE_PAIR`, banked data and the optional store policy. It uses
ordinary requests to populate every cache/window; no cache contents, guest
instructions or saved state are injected.

Run from the repository root:

```sh
bash verif/l1/run-l1d-load-store-policy-gate.sh
```

The runner enters the shared 4 GiB/64-task scope, builds serially, caps each
simulation at 30 seconds and the complete matrix at 540 seconds. Scratch and
compiler temporaries use the non-symlinked root-filesystem directory
`verif/l1/obj_dir_load_store_policy_scratch`, not the full external `tmp` volume.
Sources, build/run logs, define inventories and executable hashes are retained.

Each profile covers twelve cases: eight accepted V stores, two stalled then
withdrawn V stores, and two equal-bank rejected V stores. Accepted cases include
three backend-ignored ROM writes, three policy-masked writable RAM writes and
two all-ones RAM controls; three share U's physical tag and five use a different
tag, including the other way of the same set.

The test verifies U's already-registered value on the actual consume edge,
exactly one unchanged V backing payload/strobe, target-tag invalidation and
backing refill, no invalidation of unrelated U tags, and no effect from
unaccepted V requests. The window profile additionally creates primary U and
shadow V through real reads, and checks subsequent data/window/code reads.

Sep30 result, preserved under
`obj_dir_load_store_policy_scratch/ventium-load-store-policy.OgiIcG`:

| Profile | Result |
| --- | --- |
| Banked + policy | 215 checks; zero errors |
| Banked + policy + primary/shadow windows + code buffer | 324 checks; zero errors; 12 U windows, 8 V shadows, 12 primed code owners |
| Identical window/code profile, policy disabled | Expected RED: six actual wrong ROM data reads; zero control or RAM errors |

The negative control is not a fabricated assertion failure: accepted,
backend-ignored stores leave `07200720`, `07200620` and `07200520` in the old
resident D-line, and subsequent ordinary reads return those values instead of
the independent backing words. The fixed profiles return backing data and
preserve U's consumed value. An expected RED is reported separately, never as
a correctness pass. Compile errors, timeouts and control/RAM failures cannot
satisfy the negative-control check.

Executed input hashes:

- `ven_l1d.sv`: `98e90dce3e9327cd2e63e5efa91bea03608518e5d0e4e8e3b1cb944b0b452b39`
- Fixture: `b1c100a718017b20e6843276d7badcbb0066206e241eac67f21458c10d6182b4`
- Executed runner: `7a1674ea9bca8f597a601087b6365f496002b0ba09adf45f9bf9e4d72a408515`

After execution, the unnecessary `DECLFILENAME` waiver was removed from the
runner; its final hash is
`b7f64216f2629f1df2cd2d0355ec0b2262f6bd1dbcf1e596b3375da3ac397bf2`.
All three frozen-input profiles passed lint again with that final warning
policy. The executed runner copy is preserved; no production source changed.

This is a cache ownership/policy leaf, not the complete AXI/ao486 composition:
its independent backend acknowledges writes synchronously, ignores C–F ROM
writes and accepts RAM writes. It does not qualify delayed posted-buffer
drain, platform address folding/A20, CPU retirement, Windows desktop or Quake
timedemo. Those require their separate gates and the full standard suite.

Latest verified gameplay baseline is IPC **0.42089513**, build b7, cycles
3.0B–3.1B. It predates the store-policy candidate, which is unmeasured.
