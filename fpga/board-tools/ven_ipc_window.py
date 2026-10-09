"""Live total-U+V IPC with explicit counter-sampling uncertainty.

Only the read-only scan selector may be written. Caller owns that selector
exclusively and separately proves bitstream identity, UV/fast configuration,
workload/gameplay membership, clean execution history and completed timedemo.
This module neither starts a workload nor qualifies a gameplay result.
"""
from ven_total_retire import SELECTOR, read_total_retire
from ven_uv_fast_guard import require_running

CONTROL = 0x20
CYCLE_LO, CYCLE_HI = 0x100, 0x110
EXEC_CONTROL, EXEC_CAPABILITY, FREEZE_INFO = 0x280, 0x2C0, 0x90
COUNTER_KIND = 'total_u_plus_v_retirement_events_including_rep'


def _unsigned(value, bits, name):
    if type(value) is not int or not 0 <= value < 1 << bits:
        raise ValueError(f'{name} must be an unsigned {bits}-bit integer')
    return value


def sample(read32, write32, *, max_span_cycles=100_000):
    """Bracket a live UV64 read with stable clock-counter reads (no halt).

    The counter's exact observation cycle is somewhere inside the bracket;
    treating all three MMIO reads as simultaneous would hide that uncertainty.
    Large spans are rejected, not silently reported as precise measurements.
    """
    if type(max_span_cycles) is not int or max_span_cycles < 1:
        raise ValueError('max_span_cycles must be a positive integer')

    def read(offset):
        value = _unsigned(read32(offset), 32, 'MMIO word')
        if offset == SELECTOR and value > 127:
            raise ValueError('invalid scan selector readback')
        return value

    def write(offset, value):
        if offset != SELECTOR or type(value) is not int or not 0 <= value <= 127:
            raise ValueError('IPC observer may write only the scan selector')
        write32(offset, value)

    def running():
        if read(CONTROL) != 0x102:
            raise ValueError('guest is not running under the clean daemon control profile')
        require_running(read(EXEC_CONTROL), read(FREEZE_INFO),
                        capability=read(EXEC_CAPABILITY))

    def cycles():
        for _ in range(8):
            high = read(CYCLE_HI)
            low = read(CYCLE_LO)
            if high == read(CYCLE_HI):
                return high << 32 | low
        raise ValueError('clock counter did not produce a stable read')

    running()
    first = cycles()
    total = read_total_retire(read, write)
    last = cycles()
    running()
    if last < first or last - first > max_span_cycles:
        raise ValueError('clock reset/wrap or excessive sampling span')
    return dict(counter_kind=COUNTER_KIND, cycles_before=first, cycles_after=last,
                total_retirements=total, span_cycles=last-first,
                gameplay_qualified=False, uv_fast_history_qualified=False)


def interval(before, after):
    """Return bounds, retaining genuine zero-retirement/stalled intervals.

    A reset, overlapping sample brackets or physically impossible >2 retirements
    per clock is rejected. Counter wrap is not treated as enormous progress.
    Use ipc_lower_bound, not a rounded midpoint, for a strict acceptance target.
    """
    for endpoint in (before, after):
        if endpoint.get('counter_kind') != COUNTER_KIND:
            raise ValueError('IPC requires the capability-checked total-U+V counter')
        for key in ('cycles_before', 'cycles_after', 'total_retirements', 'span_cycles'):
            _unsigned(endpoint[key], 64, key)
        span = endpoint['cycles_after'] - endpoint['cycles_before']
        if span < 0 or endpoint.get('span_cycles') != span:
            raise ValueError('invalid endpoint clock bracket')
    minimum = after['cycles_before'] - before['cycles_after']
    maximum = after['cycles_after'] - before['cycles_before']
    retired = after['total_retirements'] - before['total_retirements']
    if minimum <= 0 or retired < 0 or retired > 2 * maximum:
        raise ValueError('overlapping/reset counters or impossible retirement rate')
    return dict(counter_kind=COUNTER_KIND, retired=retired,
                minimum_clocks=minimum, maximum_clocks=maximum,
                ipc_estimate=2 * retired / (minimum + maximum),
                ipc_lower_bound=retired / maximum,
                ipc_upper_bound=retired / minimum,
                gameplay_qualified=False, uv_fast_history_qualified=False)
