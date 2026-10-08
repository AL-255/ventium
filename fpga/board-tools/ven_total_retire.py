"""Capability-checked live U+V accounting through the existing debug scan mux.

This does not halt, clear counters, step, or change execution controls. The
caller owns exclusive use of the scan selector for the duration of a read.
Older FPGA images have no UV64 capability and must be rejected, never reported
as zero IPC. Counts include the core's existing REP-element retirement events.
"""
SELECTOR = 0x2A0
DATA = 0x2B0
CAPABILITY = 0x55563634


def read_total_retire(read32, write32):
    """Callbacks access control-MMIO offsets; only SELECTOR may be written."""
    previous = read32(SELECTOR)
    selected = previous

    def select_read(selector):
        nonlocal selected
        write32(SELECTOR, selector)
        selected = selector
        if read32(SELECTOR) != selector:
            raise RuntimeError('debug scan selector changed concurrently')
        value = read32(DATA)
        if read32(SELECTOR) != selector:
            raise RuntimeError('debug scan selector changed concurrently')
        return value

    try:
        if select_read(78) != CAPABILITY:
            raise RuntimeError('installed image lacks total-U+V UV64 capability')
        for _ in range(8):
            hi = select_read(77)
            lo = select_read(76)
            if hi == select_read(77):
                return (hi << 32) | lo
        raise RuntimeError('total-U+V counter did not produce a stable read')
    finally:
        # Do not overwrite another observer's selector on the failure path.
        if read32(SELECTOR) == selected:
            write32(SELECTOR, previous)
