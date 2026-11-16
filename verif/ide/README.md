# Production IDE PIO Interrupt Leaf Gate (`verif/ide/`)

`verif/ide/` instantiates the production `ao486` `ide.v` controller and its dual-port sector buffer RAM to verify ATA PIO interrupt edges, status acknowledgement, and multi-block handshakes without forcing internal DUT signals.

## Contract & Stimulus (`run-pio-irq-gate.sh`)

Per ATA/ATAPI and QEMU 8.2.2 `hw/ide/core.c` (`ide_sector_read_cb` / `ide_sector_read`), a PIO **READ** raises one IRQ as each 256-word data block becomes ready (`DRQ=1`) and must **not** raise a spurious trailing IRQ when the host drains the final word of the last block, whereas a PIO **WRITE** raises its completion IRQ after the host writes the block and management publishes completion. Reading regular status (`0x1F7`) acknowledges the IRQ; reading alternate status (`0x3F6`) does not.

`run-pio-irq-gate.sh` exercises **11 cases** (**2,623 checks**, **2,560 patterned words**) inside `tools/build_scope.sh` with all six structural lint classes fatal:

1. Single-sector `READ` with regular-status ACK before the 256-word drain (1 IRQ edge, not 2).
2. Alternate-status (`0x3F6`) non-acknowledging read control.
3. `nIEN=1` interrupt-masking control.
4. Two-sector `READ` (2 IRQ edges, not 3).
5. `WRITE` data/readback followed by management completion IRQ publication.
6. `READ MULTIPLE` and `IDENTIFY DEVICE`.
7. Non-data good and error command completion IRQs.
8. Same-clock descriptor word-5 IRQ publication vs host status-read priority.
9. Command supersession immediately after block drain, plus software reset (`SRST`).

## Running

```sh
bash verif/ide/run-pio-irq-gate.sh                 # production correctness gate (IDE-PIO-IRQ-GATE-OK)
python3 -B verif/ide/test_pio_irq_classifier.py    # 14 host-only classifier accept/reject unit tests
```

(`EXPECT_RED=1 bash verif/ide/run-pio-irq-gate.sh` is a negative-control classifier mode for the pre-fix `ide.v` that raised `block_done_irq` on read drain; an expected RED is never a correctness PASS.)

## Hardware Status

The fixed `ide.v` (`68750b04...`, `IDE-PIO-IRQ-GATE-OK`) is deployed in the board-qualified **`c0e3fe43`** release on **RK-XCZU15EG-F**, passing cold FreeDOS/DOS Quake `demo1` (`8.0 FPS`, **`0.515778001` total U+V / `0.397847833` primary/U gameplay IPC** across cycles `28,696,827,616–32,989,404,795`) and cold Windows 95 OSR2 boot + clean shutdown.
