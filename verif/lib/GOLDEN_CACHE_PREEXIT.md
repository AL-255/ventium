# Functional golden-cache exit-observer isolation

Current status: **the composed repair is installed** in `verify_worker.sh` as
of October 15, after both source-pinned FPGA measurements closed. The private
qualification history below is retained; it is not a canonical-suite pass.

## Confirmed defect and private repair (2026-10-13)

`verify_worker.sh` hashes the QEMU binary into its functional golden-cache
key, but omits `VTM_QEMU_GDB_PREEXIT`. The qualified observer binary produces
different terminal records with that option enabled or disabled. Sharing the
key makes the verdict depend on which mode populated the cache first.

Four parallel sequences ran the **real worker, QEMU, RTL model and comparator**,
not mocks. The unchanged `smoke` program produces 22 RTL records (14 U + 8 V)
with `--cycle-func --l1-axi`, AXI read/write latency 7. QEMU produces 21 records
with the observer disabled, 22 enabled. Results across 14 native executions:

| Worker / cache fill order | First execution | Second execution |
|---|---|---|
| Original: disabled, enabled | FAIL, fresh 21-record golden | **FAIL, stale disabled-mode hit** |
| Original: enabled, disabled | PASS, fresh 22-record golden | **PASS, stale enabled-mode hit** |
| Repaired: disabled, enabled | FAIL, fresh | PASS, separate fresh entry |
| Repaired: enabled, disabled | PASS, fresh | FAIL, separate fresh entry |

The stale-mode PASS is not proof that defective RTL passed: this smoke program
is correct. It proves the requested oracle mode was not used. The disabled
mode's native length mismatch is deliberately retained, not masked or waived.

[`prepare_preexit_cache.py`](prepare_preexit_cache.py) changes only the
functional key to include `.preexit0` or `.preexit1`. Only literal `1` enables
the observer; unset, empty, `0`, `yes` and `01` all share the disabled entry.
Warm-hit tests confirm both mode isolation and that normalization. Cycle keys,
trace generation, comparison, masks and tolerance bands are unchanged. Existing
functional keys are naturally invalidated rather than reused or deleted.

The recipe hash-checks the original worker and rejects drift/reapplication.
Shell syntax, exact reversal and those rejection checks pass. The canonical
worker remains **unchanged**, because live build/run ledgers pin it. This is a
tested private repair awaiting deliberate promotion, not a green canonical
gate, a promoted QEMU oracle, or standard-suite acceptance.

## Reproduction and evidence

Run [`test_preexit_cache_native.py`](test_preexit_cache_native.py) with
`--out` pointing to a fresh directory under `/home/yukidama/external/tmp`,
`TMPDIR` set to that external directory, and a systemd user owner. The test
requires actual controller affinity 13–16 and pins each sequence to one CPU.
It observes the real QEMU and RTL children's affinity, waits/reaps each worker,
rechecks its inputs and retains original/repaired logs and cache contents.
It uses existing qualified binaries; it does not compile or replace them.

- Evidence: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X/preexit-cache-r1`.
- Owner: `ventium-preexit-cache-oct13-r1.service`, invocation
  `08d6baededff42e9adac2189eb62f7a7`; terminal MainPID 0 / exit 0.
  Limits: 1 GiB RAM, no swap, 256 tasks, 240 seconds. All OOM counters zero.
- Current direct-core model:
  `fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041`.
- Private QEMU:
  `da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d`.
- Private repaired worker:
  `cc07db7c9d1adcf2b13b4ea03c91bf0dd9bea3c247e276cc8d8701195e5dd179`.
- `closed.json` SHA-256:
  `b8be90b071e824dabcf4cfe381b87ba3fbbb65e3716d557c8f121b9daeee6de4`.

No gameplay/performance measurement results from this verification repair.

## Composed cycle-lookup repair qualified — October 15

The cycle worker also looked for the obsolete source-only functional key,
omitting the ELF and oracle identities already required by the functional
producer. Consequently its initial-ESP lookup normally missed a valid cached
trace and fell back to the default. The new
[composed recipe](prepare_worker_cache_identity.py) applies the qualified
functional mode-key fix and makes that lookup use the **same complete key**.
Cycle golden identities are deliberately unchanged: the exit hook does not
run without an attached debugger. No default observer setting is enabled.

[Three host tests](test_worker_cache_identity.py) check exact reversal, shell
syntax, both functional/lookup key expressions, literal-1 normalization,
unchanged cycle keys, source drift, reapplication and partial-repair refusal.
The [native test](test_worker_cache_identity_native.py) reuses the fourteen
original actual-worker sequences and adds cycle executions in both observer
modes. **All 16 checks pass**. The old stale-mode PASS/FAIL witnesses remain;
the repaired worker retains the expected real length failure when disabled.
Both cycle runs use the actual matched golden's ESP and retire 22 instructions,
including eight V retirements. The second cycle run correctly reuses the first
cycle golden despite changing observer mode. Their cycle timing comparisons
remain exit 1; this cache test does not qualify a cycle band or processor gate.

Owner `ventium-worker-cache-identity-oct15-r2.service`, invocation
`9233984c1212472cbfc19aa289904ca4`, is terminal, native exit 0 / MainPID 0.
Peak RAM is 91,729,920 bytes, with no OOM. Four independent sequences observe
their real children on CPUs13–16; the additional cycle children are observed on
CPU13. Source pins are unchanged, all workers are waited/reaped. QEMU/model
identities remain those above; this is not a newer processor measurement.

Evidence: `external/tmp/ventium-data-size.v2HaTO2X/worker-cache-identity-r2`.
`composed-closed.json` SHA-256:
`44f0e788f774cd044c9a00d51648a605d96195eddf61286ccdb12eecda744066`.
Qualified repaired worker SHA-256:
`a39a497a74a92deef65c648a535835192085e904e8dffb497ef64aec7c6aa3e6`.
R1 fails before launching tests because the adapter assumed the earlier
single-replacement recipe interface. R2 calls the unchanged sequence checker
directly and checks exact reversal of the composed transformation. No RTL,
expected verdict or comparator was altered to resolve that driver error.

**Installation is pending the live FPGA measurement's source-pin release.**
The production worker and canonical reference are still unchanged as of this
entry. Reproduction requires the recipe's exact predecessor worker and a fresh
external output leaf, bounded retained systemd owner (1 GiB/no swap, 256 tasks,
240 seconds) and explicit `taskset -c 13-16`. Do not promote this verification
repair as a green canonical gate or a hardware performance improvement.

## Production installation — October 15

The synthesis, clock-audit and queue owners are terminal, MainPID 0 / exit 0
(identities in [the closed timing report](../fe_pipe/PREFIX_OPCODE.md#closed-full-core-result-reject-the-opcode-selector)).
Only then were the exact two qualified replacements applied to the production
worker. Its SHA-256 is
`a39a497a74a92deef65c648a535835192085e904e8dffb497ef64aec7c6aa3e6`,
byte-identical to the worker used by all 16 native checks above. The three
host tests, `bash -n`, byte comparison and diff whitespace check pass after
installation. No RTL, reference binary, trace record, mask or cycle band changed.

Earlier closed evidence pins the original production-worker bytes. Those pins
remain valid historical identities, not a claim that the current file is still
unchanged. The original worker is recoverable at commit `bcd80f23`; the native
qualification driver intentionally requires that predecessor and refuses a
partially repaired or already repaired input. Host tests support the installed
worker by exact reversal. Future native replay must explicitly preserve that
old/new comparison rather than silently treating the repaired worker as old.

This prevents stale observer-mode cache reuse and repairs the cycle worker's
functional-ESP lookup. It does **not** enable/promote the private QEMU observer,
resolve the remaining canonical reference divergences or improve hardware IPC.
