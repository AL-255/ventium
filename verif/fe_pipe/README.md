# Registered-translation cut experiment (not enabled)

`prototype/ven_fe_dtlb.sv` and `prototype/core-integration.patch` preserve the
eight-entry experiment described in
[the measured audit](../../docs/UV_FAST_TRANSLATION_CUT_2026-10-08.md).
They are deliberately outside production filelists. No core/default/build mode
is changed by this directory. The leaf gate does not test the deployed FPGA.

Run the deterministic leaf regression:

```sh
bash verif/fe_pipe/run-leaf.sh
```

The private full-core experiment applies the patch to a frozen repaired107
source tree, adds the module to its explicit filelist, and adds **only**
`VEN_FE_PIPE` and `VEN_FE_DTLB_MULTI` to that exact define set. It keeps
`cycle_mode=1`, U/V issue, all system fast paths, and the full P54 caches.
`VEN_FE_PIPE` denotes the registered-translation experiment, not the ordinary
system fast pipeline. Do not apply this unqualified patch to production or
mistake its absence for a U-only/slow-pipeline configuration.

The leaf checks reset/flush dominance, dirty updates, cached miss results,
duplicate ownership, colliding page tags, eight-page residency and replacement.
The parent must invalidate **all** children on **every** DTLB fill/replacement
and every context flush. Permissions remain in that parent. Retaining a child
after parent replacement could bypass a required page walk/permission check.

Remaining requirements include timing/area assessment, memory-chain/prime
configuration coverage, true per-instruction U/V architectural trace snapshots,
and the complete standard suite plus original 40 MHz cold FPGA timedemo.
Native exits, terminal witnesses and microbenchmarks alone cannot close these.
