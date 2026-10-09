"""Passive IPC evidence for the pinned DOS Quake 1.06 demo1 workload.

This is an observer, never a guest repair or a benchmark acceptance checker.
The caller must pin the original media/image, own the debug scan selector,
prove cold UV/fast execution and independently verify completed timedemo/video.
The four engine offsets describe that executable's known DPMI mapping only;
they must not be applied to arbitrary Quake builds or interpreted as coherent
architectural state. Reads of physical RAM do not snoop dirty CPU cache lines.
"""
from collections import Counter

from ven_ipc_window import interval as counter_interval, sample

PAGE_DIRECTORY = 0x7e000
DATA_BASE = 0x10000000
RAM_BYTES = 0x1000000
FIELDS = (('demo_active', 0x6c980), ('demo_file', 0x6c988),
          ('host_framecount', 0x95bb4), ('td_startframe', 0x6c990))
# Fixed before seeing candidate results; same interior window as the previous
# hardware write profile. Boundaries are raw host_framecount - td_startframe.
FIRST_FRAME, LAST_FRAME = 33, 900


def engine_status(read_phys32):
    """Double-read the known engine fields, refusing changing page mappings.

    Only aligned scalar physical reads occur. Malformed/nonresident/large-page
    mappings are unavailable evidence, never an invitation to access outside
    the reserved guest RAM. Unexpected I/O errors propagate to the controller.
    """
    def word(address):
        if type(address) is not int or address & 3 or not 0 <= address <= RAM_BYTES-4:
            raise ValueError('physical word outside guest RAM')
        value = read_phys32(address)
        if type(value) is not int or not 0 <= value < 1 << 32:
            raise ValueError('physical read is not an unsigned word')
        return value

    def field(offset):
        linear = DATA_BASE + offset
        directory_address = PAGE_DIRECTORY + ((linear >> 22) & 1023)*4
        directory = word(directory_address)
        if not directory & 1 or directory & 128:
            raise ValueError('engine PDE unavailable or large-page')
        table_address = (directory & 0xfffff000) + ((linear >> 12) & 1023)*4
        entry = word(table_address)
        if not entry & 1:
            raise ValueError('engine PTE unavailable')
        physical = (entry & 0xfffff000) | (linear & 4095)
        value = word(physical)
        if word(table_address) != entry or word(directory_address) != directory:
            raise ValueError('engine page mapping changed during read')
        return value

    try:
        first = {name: field(offset) for name, offset in FIELDS}
        second = {name: field(offset) for name, offset in FIELDS}
        if first != second:
            raise ValueError('engine fields changed during double-read')
        return dict(first, available=True)
    except ValueError as error:
        return dict(available=False, reason=str(error))


def endpoint(read32, write32, read_phys32):
    """Surround the bounded UV64 sample with independent engine witnesses."""
    before = engine_status(read_phys32)
    counters = sample(read32, write32)
    return dict(engine_before=before, counters=counters,
                engine_after=engine_status(read_phys32))


def _engine(record):
    before, after = record['engine_before'], record['engine_after']
    if before != after or before.get('available') is not True:
        raise ValueError('unavailable or changing engine witness')
    for name, _ in FIELDS:
        if type(before[name]) is not int or not 0 <= before[name] < 1 << 32:
            raise ValueError('malformed engine field')
    if before['demo_active'] != 1 or before['demo_file'] == 0:
        raise ValueError('timedemo inactive')
    frame = before['host_framecount'] - before['td_startframe']
    if not FIRST_FRAME <= frame <= LAST_FRAME:
        raise ValueError('outside predefined gameplay interior')
    return before


def interval(before, after):
    """Grade membership separately from counter integrity, never filter on IPC.

    Counter reset/invalid mode is a hard error even outside gameplay. Equal
    frame counts and zero retirements are valid (possibly stalled) intervals.
    Filtering those would bias the score upward. No invalid endpoint is skipped
    to bridge two more favorable endpoints into a fabricated interval.
    """
    counts = counter_interval(before['counters'], after['counters'])
    try:
        first, last = _engine(before), _engine(after)
        if any(first[k] != last[k] for k in ('demo_file', 'td_startframe')):
            raise ValueError('timedemo identity changed')
        if last['host_framecount'] < first['host_framecount']:
            raise ValueError('frame counter regressed')
    except ValueError as error:
        return dict(counts, membership_observed=False, reason=str(error))
    return dict(counts, membership_observed=True, reason=None,
                first_frame=first['host_framecount']-first['td_startframe'],
                last_frame=last['host_framecount']-last['td_startframe'])


class Accumulator:
    """All consecutive intervals, weighted by clocks, with rejected coverage.

    This deliberately does not call a score verified gameplay or a target pass:
    engine witnesses, native closure, cache visibility, clean execution history
    and capture coverage still need an independent audit.
    """
    def __init__(self):
        self.previous = None
        self.endpoints = self.accepted = 0
        self.retired = self.minimum = self.maximum = 0
        self.rejected = Counter()
        self.first = self.last = None

    def add(self, record):
        result = None
        if self.previous is not None:
            result = interval(self.previous, record)
            if result['membership_observed']:
                self.accepted += 1
                self.retired += result['retired']
                self.minimum += result['minimum_clocks']
                self.maximum += result['maximum_clocks']
                if self.first is None:
                    self.first = dict(cycles=self.previous['counters']['cycles_before'],
                                      frame=result['first_frame'])
                self.last = dict(cycles=record['counters']['cycles_after'], frame=result['last_frame'])
            else:
                self.rejected[result['reason']] += 1
        self.previous = record
        self.endpoints += 1
        return result

    def result(self):
        return dict(scope='OBSERVED_GAMEPLAY_INTERIOR_NOT_ACCEPTANCE',
                    frame_window=[FIRST_FRAME, LAST_FRAME], endpoints=self.endpoints,
                    included_intervals=self.accepted, excluded_intervals=dict(self.rejected),
                    retired=self.retired, minimum_clocks=self.minimum, maximum_clocks=self.maximum,
                    ipc_estimate=2*self.retired/(self.minimum+self.maximum) if self.maximum else None,
                    ipc_lower_bound=self.retired/self.maximum if self.maximum else None,
                    ipc_upper_bound=self.retired/self.minimum if self.minimum else None,
                    first=self.first, last=self.last, acceptance=False, target_pass=False,
                    full_timedemo=False, uv_fast_history_qualified=False)
