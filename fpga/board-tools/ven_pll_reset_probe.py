#!/usr/bin/env python3
"""One fail-closed startup reset diagnostic on the pinned programmable image.

The generated PS wrapper connects pl_resetn0 to EMIO95, Linux GPIO offset173.
Only that unclaimed line is requested; no PS register, PCAP or core-MMIO access.
This is a whole-fabric reset diagnostic, never a normal frequency-change path.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import time

from ven_pll_clock import GpioMailbox, SET_VALUES, decode

FIRMWARE = Path('/lib/firmware/ventium_programmable_clock_40_oct16_reuse2.bit.bin')
IMAGE_SHA = 'b9cd2144880c9bdf5f85988801fb4c45f9d59eda15e6d6105dac329c81778a45'


def probe_reset(box, *, set_values, sleep=time.sleep, monotonic=time.monotonic):
    before = decode(box.read())
    if (before['busy'] or not before['error'] or before['clock_enabled'] or
            before['locked'] or not before['mmcm_reset'] or before['divider'] != 25):
        raise ValueError('diagnostic requires the observed failed/gated 40 MHz startup')
    reset_fd = box.request((173,), 2)  # exclusive claim, initial zero asserts reset
    held = None
    try:
        sleep(.05)
        held = decode(box.read())
        if held['error'] or not held['busy'] or not held['mmcm_reset'] or held['clock_enabled']:
            raise ValueError('PL reset did not reach the clock controller')
    finally:
        try:
            released_at = monotonic()
            set_values(reset_fd, bytearray([1]+[0]*63))
        finally:
            os.close(reset_fd)
    transitions = []
    deadline = released_at + .5  # exceeds the hardware's 2^24 / 100 MHz timeout
    while True:
        after = decode(box.read())
        elapsed = monotonic() - released_at
        if not transitions or transitions[-1]['status'] != after:
            transitions.append(dict(seconds_after_release=elapsed, status=after))
        if not after['busy'] or monotonic() >= deadline:
            break
        sleep(.0002)
    ready = (not after['busy'] and not after['error'] and after['locked'] and
             after['clock_enabled'] and not after['mmcm_reset'] and after['divider'] == 25)
    return dict(before=before, held=held, after=after, clock_ready=ready,
                transitions=transitions, observed_elapsed_seconds=elapsed,
                reprogrammed=False, acceptance=False, gameplay_ipc=None)


def main():
    if os.geteuid() != 0:
        raise PermissionError('board root required')
    with FIRMWARE.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != IMAGE_SHA:
            raise ValueError('wrong programmed-image firmware identity')
    if Path('/sys/class/fpga_manager/fpga0/state').read_text().strip() != 'operating':
        raise ValueError('FPGA manager not operating')
    from ven_coremark_clock_trial import no_daemon
    no_daemon()
    box = GpioMailbox()
    try:
        result = probe_reset(box, set_values=lambda fd,data: fcntl.ioctl(fd, SET_VALUES, data, True))
        print(json.dumps(result, indent=2), flush=True)
    finally:
        box.close()
    return 0 if result['clock_ready'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
