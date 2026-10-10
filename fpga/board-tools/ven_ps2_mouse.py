"""General three-button PS/2 mouse policy for the hosted byte transport.

No MMIO, guest-memory or IRQ access. The adapter MUST resolve an admitted TX
byte (done/abort) before passing an RX command, and invalidate tokens on the
same reset as the 8042. See ../PS2_DEVICE.md for the still-missing adapter.

Input deltas are sensor counts at the selected resolution: +X right, +Y up.
Unlike a physical overflowing sensor, this hosted input queues bounded motion
and splits it into representable packets, never inventing overflow/wheel data.
Only successful delivery of a whole packet consumes its input counts.
"""
from collections import deque
from dataclasses import dataclass


@dataclass
class _Packet:
    data: bytes
    # generation, unscaled X/Y consumed, sampled button state
    motion: tuple | None = None
    remember: bool = True


class Mouse:
    RATES = (10, 20, 40, 60, 80, 100, 200)
    MAX_PENDING = 1 << 20

    def __init__(self):
        self._serial = 0
        self._generation = 0
        self.reset()

    def reset(self):
        """Hardware reset; adapter must also reset the physical transport."""
        self._serial += 1  # A completion from before reset can never match.
        self._flight = None
        self._queue = deque()
        self._index = 0
        self._last = None
        self.buttons = 0
        self._reported_buttons = 0
        self._now = 0
        self._due = 0
        self._defaults()
        self._queue.append(_Packet(bytes((0xAA, 0x00))))

    def _clear_motion(self):
        self.dx = self.dy = 0
        self._generation += 1

    def _defaults(self):
        self.enabled = self.remote = self.wrap = self.scaling = False
        self.rate = 100
        self.resolution = 2
        self.parameter = None
        self._bad_parameter = False
        self._clear_motion()

    def input(self, dx=0, dy=0, buttons=None):
        """Record one sensor sample, even when stream reporting is disabled.

        Buttons use packet order: left=1, right=2, middle=4. No silent input
        loss on queue overflow: reject the entire sample before changing state.
        The UI producer must retry/backpressure and sample the current resolution.
        """
        if type(dx) is not int or type(dy) is not int:
            raise ValueError('motion must be integer sensor counts')
        if buttons is not None and (type(buttons) is not int or not 0 <= buttons <= 7):
            raise ValueError('buttons must be a three-bit integer')
        possible = [(self.dx + dx, self.dy + dy)]
        # Opposite-direction input can cancel an in-flight snapshot. Reserve
        # room for its later commit too, otherwise that subtraction could
        # exceed the advertised backlog bound after a seemingly valid sample.
        for packet in (*self._queue, self._last):
            if packet is not None and packet.motion is not None:
                generation, x, y, _ = packet.motion
                if generation == self._generation:
                    possible.append((self.dx + dx - x, self.dy + dy - y))
        if any(abs(x) > self.MAX_PENDING or abs(y) > self.MAX_PENDING for x, y in possible):
            raise OverflowError('hosted mouse motion backlog is full')
        if buttons is not None:
            self.buttons = buttons
        if self.wrap:
            return
        self.dx += dx
        self.dy += dy

    @staticmethod
    def _scale(value):
        n = abs(value)
        scaled = (0, 1, 1, 3, 6, 9)[n] if n < 6 else 2 * n
        return -scaled if value < 0 else scaled

    def _movement(self, *, stream):
        scaled = self.scaling and stream
        # A virtual sensor preserves excess counts for subsequent reports.
        # Limit before 2:1 scaling so the result always fits signed 9 bits.
        limit = 127 if scaled else 255
        x = max(-limit, min(limit, self.dx))
        y = max(-limit, min(limit, self.dy))
        sx, sy = (self._scale(x), self._scale(y)) if scaled else (x, y)
        header = 8 | self.buttons | (0x10 if sx < 0 else 0) | (0x20 if sy < 0 else 0)
        return _Packet(bytes((header, sx & 255, sy & 255)),
                       (self._generation, x, y, self.buttons))

    def _reply(self, *values, remember=True):
        self._queue.append(_Packet(bytes(values), remember=remember))

    def receive(self, value, *, errors=0):
        """One completed host byte, after resolving TX ownership/preemption.

        Parity/stop errors request retransmission without executing the byte.
        Commands supersede the unsent suffix of an old response. RESEND replays
        the last packet with a delivered prefix, not an unadmitted queue item.
        """
        if type(value) is not int or not 0 <= value <= 255 or errors not in (0, 1, 2, 3):
            raise ValueError('invalid received byte/framing flags')
        if self._flight is not None:
            raise RuntimeError('resolve TX completion/abort before receiving a command')
        self._queue.clear()
        self._index = 0
        if errors:
            self._reply(0xFE, remember=False)
            return
        if self.wrap and value not in (0xEC, 0xFF):
            self._reply(value)
            return
        if value == 0xFE:
            if self._last is None:
                self._reply(0xFE, remember=False)
            else:
                self._queue.append(self._last)
            return
        if value == 0xFF:
            self._defaults()
            self._reply(0xFA)
            self._reply(0xAA, 0x00)
            return
        if self.parameter is not None:
            valid = value in self.RATES if self.parameter == 0xF3 else value <= 3
            if not valid:
                self._reply(0xFC if self._bad_parameter else 0xFE, remember=False)
                if self._bad_parameter:
                    self.parameter = None
                self._bad_parameter = not self._bad_parameter
                return
            if self.parameter == 0xF3:
                self.rate = value
            else:
                self.resolution = value
            self.parameter = None
            self._bad_parameter = False
            self._clear_motion()
            self._reply(0xFA)
            self._due = self._now + self._interval()
            return
        if value not in (0xF6, 0xF5, 0xF4, 0xF3, 0xF2, 0xF0,
                         0xEE, 0xEC, 0xEB, 0xEA, 0xE9, 0xE8, 0xE7, 0xE6):
            self._reply(0xFE, remember=False)
            return
        self._reply(0xFA)
        if value == 0xEB:
            self._queue.append(self._movement(stream=False))
            return
        if value == 0xF6:
            self._defaults()
        elif value == 0xF5:
            self.enabled = False
        elif value == 0xF4:
            self.enabled = True
        elif value in (0xF3, 0xE8):
            self.parameter = value
            self._bad_parameter = False
        elif value == 0xF2:
            self._reply(0x00)  # Standard mouse: no wheel-mode magic sequence.
        elif value == 0xF0:
            self.remote = True
        elif value == 0xEE:
            self.wrap = True
        elif value == 0xEC:
            self.wrap = False
        elif value == 0xEA:
            self.remote = False
        elif value == 0xE9:
            # Status button order differs from movement-packet button order.
            status = ((self.remote << 6) | (self.enabled << 5) | (self.scaling << 4)
                      | ((self.buttons & 1) << 2) | ((self.buttons & 4) >> 1)
                      | ((self.buttons & 2) >> 1))
            self._reply(status, self.resolution, self.rate)
        elif value in (0xE6, 0xE7):
            self.scaling = value == 0xE7
        self._clear_motion()
        self._due = self._now + self._interval()

    def _interval(self):
        return (1_000_000_000 + self.rate - 1) // self.rate

    def advance(self, now_ns):
        """Monotonic device time; at most one pending spontaneous packet.

        Adapter calls this after servicing RX/completion events, never before.
        Slow host polling delays samples rather than emitting a catch-up burst.
        """
        if type(now_ns) is not int or now_ns < self._now:
            raise ValueError('mouse time must be monotonic integer nanoseconds')
        self._now = now_ns
        if (not self._queue and self._flight is None and self.parameter is None
                and self.enabled and not self.remote and not self.wrap and now_ns >= self._due
                and (self.dx or self.dy or self.buttons != self._reported_buttons)):
            self._queue.append(self._movement(stream=True))
            self._due = now_ns + self._interval()

    def peek(self):
        """Stable offered byte; observing it does not transfer ownership."""
        if self._flight is not None or not self._queue:
            return None
        return self._queue[0].data[self._index]

    def admitted(self):
        """Call ONLY after the CSR/transport confirms admission of peek()."""
        value = self.peek()
        if value is None:
            raise RuntimeError('no offered mouse byte to admit')
        self._serial += 1
        self._flight = self._serial
        return self._flight, value

    def completed(self, token, *, delivered):
        """Resolve exactly one admitted byte; aborted packets restart at byte 0."""
        if token != self._flight or self._flight is None or type(delivered) is not bool:
            raise RuntimeError('stale/duplicate mouse TX completion')
        self._flight = None
        if not delivered:
            self._index = 0
            return
        packet = self._queue[0]
        if packet.remember:
            self._last = packet
        self._index += 1
        if self._index == len(packet.data):
            if packet.motion is not None:
                generation, x, y, buttons = packet.motion
                if generation == self._generation:
                    self.dx -= x
                    self.dy -= y
                    self._reported_buttons = buttons
                packet.motion = None  # RESEND must never consume movement twice.
            self._queue.popleft()
            self._index = 0
