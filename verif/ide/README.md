# Production IDE PIO interrupt leaf

`run-pio-irq-gate.sh` freezes and instantiates the actual ao486 `ide.v` and its
existing simulation dual-port RAM. All management descriptors, data, commands
and status acknowledgements pass through public ports; no DUT state is forced.
The serialized build guard remains active, tightened to 2GiB/no swap/64 tasks;
one compiler, a 120-second guarded build/run deadline (lock waiting excluded),
and a 20-second DUT deadline. Scratch stays
on the real repository root filesystem, not the external `tmp` symlink.

Cases cover single-sector READ with regular-status acknowledgement before the
256-word drain; alternate-status no-ack control; pre-established nIEN control;
two successive READ blocks; and WRITE data/readback followed by management
publication of the final completion IRQ; READ MULTIPLE and IDENTIFY; nondata
GOOD/error IRQs; same-clock word-5 publication/status-read priority; command
supersession after drain; and device reset. They check exact patterned words,
DRQ, status, request ownership, completion count and IRQ rising edges. The WRITE
case does not claim disk persistence or a full-PC interrupt-delivery test.

The intended read contract is one IRQ when each data block becomes ready, no
second IRQ just because the last READ block is drained. The pinned QEMU 8.2.2
`hw/ide/core.c` publishes that IRQ in `ide_sector_read_cb`; its final
`ide_sector_read` branch stops the transfer without raising another IRQ. A
WRITE instead raises its completion IRQ after data is consumed. Regular status
acknowledges; alternate status does not.

Run `bash verif/ide/run-pio-irq-gate.sh` for the correctness gate. On the old,
unfixed source, a deliberate negative qualification is
`EXPECT_RED=1 bash verif/ide/run-pio-irq-gate.sh`: it
accepts only the exact four extra-data-in-IRQ failures with zero other control/data
failures, never a compile error, timeout or general failure. An expected RED is
not a correctness PASS. The classifier additionally requires all 2,623 checks
and the exact four IRQ/edge/status/count/request signatures; four arbitrary
IRQ failures, such as missing interrupts, cannot qualify as this known RED.
Run `python3 -B verif/ide/test_pio_irq_classifier.py` for 14 host-only
accept/reject cases against the actual runner classifier; this does not build
or execute a DUT and does not replace hardware correctness qualification.
Artifacts retain frozen source, hashes, limits, build
and runtime logs. No waivers beyond `-Wno-UNUSED`; six structural classes are
hard errors.

This fixture does not yet establish Win95 semaphore ownership or a stall
cause, nIEN pending-IRQ re-enable semantics, simultaneous descriptor/new-command
ordering beyond the explicit status/publication collision, full-system PIC
acceptance, ATAPI or DMA behavior.

The 2026-09-30 negative qualification completed on frozen `ide.v` SHA-256
`9c9d94151969fbd08f82b7016eb12dd43fc571cba566056a77bd8878cd179592`.
Artifacts: `obj_dir_pio_irq_scratch/ide-pio-irq.NaYEby`. All 2,560 patterned
data words and other controls passed: 2,623 checks, exactly four extra-data-in
IRQ failures, zero control errors. Single READ and IDENTIFY had two rising
edges instead of one; two-block READ and READ MULTIPLE had three instead of
two. This is clean expected RED, not correctness PASS or Win95-cause proof.
The preceding smaller five-case qualification remains in `ide-pio-irq.WymIPp`.

The matching GREEN qualification used the **identical testbench, runner and
simulation RAM** against the minimal production change: remove the drain-time
IRQ raise and its now-unused `block_done_irq` descriptor field; leave word-5
IRQ publication, backing-data ownership and regular/alternate status priority
unchanged. Frozen fixed `ide.v` SHA-256:
`68750b047a6eeee6835862b4ee568800f861e47862c7fc9d084b800b546f2e16`.
Artifacts: `obj_dir_pio_irq_scratch/ide-pio-irq.AR1mX3`; 2,623 checks,
2,560 exact patterned data words, **zero IRQ errors and zero control errors**,
`IDE-PIO-IRQ-GATE-OK`, process exit 0. This covers all eleven cases above,
including WRITE completion and simultaneous publication/status acknowledgement.
The fixed binary SHA-256 is
`8f8272206ce0639178558bf3b3b98fe3ffa82c9d018df17204d439c58dcdb261`;
its structured receipt retains source, runtime log and resource-cap hashes.

This is a production-device leaf qualification, not the standard suite or a
demonstration that the Win95 wait was caused by the duplicate interrupt. The
last verified gameplay IPC is 0.44240609 on build `2e63`, cycles 2.4B–2.5B;
that measured build predates the IDE fix. The IDE-fixed candidate has no
gameplay measurement yet.
