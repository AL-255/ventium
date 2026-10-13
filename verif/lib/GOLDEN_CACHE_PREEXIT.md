# Functional golden-cache exit-observer isolation

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
