"""Single-owner software state machine for ven_ps2_mailbox ABI 1.

This module does not open /dev/mem, reset the guest, or invent delivery events.
The caller supplies ordered, full-strobe 32-bit read/write callbacks using CSR
*indices*, owns the transport exclusively, and keeps the fabric identity fixed.
The first attachment requires observed guest reset. A process cannot attach a
fresh Mouse policy to a running device. A native MMIO service and real-wire
qualification remain separate requirements; fake-register tests are not either.

Each poll performs bounded coherent reads and at most one write. A write's
readback may lag: retain the pending command, never repeat it speculatively.
Only sequence advancement admits TX; only acknowledged retained events commit
policy state. RX is consumed after prior TX completion/abort. Reset generations
invalidate outstanding policy ownership, including writes crossing reset.
"""
from dataclasses import dataclass

from ven_ps2_mouse import Mouse


CAPABILITY = 0x50533201
RESET, ARMED, READY, QUEUED, ACTIVE, EVENT, DELIVERED, RX_FULL, RX_ABORT, ERROR, EXHAUSTED = (
    1 << n for n in range(11))
TX_STATE = QUEUED | ACTIVE | EVENT
MASK32 = (1 << 32) - 1


class MailboxError(RuntimeError):
    pass


@dataclass(frozen=True)
class Snapshot:
    generation: int
    status: int
    tx: int
    rx: int
    data: int


class Adapter:
    def __init__(self, read32, write32, *, command_timeout_ns=100_000_000):
        if type(command_timeout_ns) is not int or command_timeout_ns <= 0:
            raise ValueError('positive command deadline required')
        self._read, self._write = read32, write32
        self.timeout = command_timeout_ns
        self.failed = None
        self.pending = None
        self.flight = None
        self._mouse = Mouse()
        self.tx_sequence = self.rx_sequence = 0
        self.armed = False
        self.in_reset = True
        self.reset_write_race = False
        self.last_time = -1
        self.epoch_time = 0
        if self._word(0) != CAPABILITY:
            raise MailboxError('unsupported mouse mailbox capability')
        first = self._snapshot()
        if first is None or first.status != RESET or first.tx or first.rx:
            raise MailboxError('fresh adapter requires stable, clean held guest reset')
        self.generation = first.generation

    def _word(self, index):
        value = self._read(index)
        if type(value) is not int or not 0 <= value <= MASK32:
            raise MailboxError('invalid 32-bit CSR value')
        return value

    def _snapshot(self):
        for _ in range(4):
            epoch = self._word(2)
            status = self._word(1)
            tx, rx = self._word(5), self._word(8)
            data = self._word(7) if status & RX_FULL else 0
            end_status, end_epoch = self._word(1), self._word(2)
            if (epoch, status) != (end_epoch, end_status):
                continue
            if status & ~0x7ff or data & ~0x3ff:
                raise MailboxError('reserved mailbox bits set')
            states = status & TX_STATE
            if states and states & (states - 1):
                raise MailboxError('contradictory TX ownership')
            if status & DELIVERED and not status & EVENT:
                raise MailboxError('delivery without retained event')
            if status & READY and (not status & ARMED or status & (
                    RESET | TX_STATE | RX_FULL | ERROR)):
                raise MailboxError('contradictory TX readiness')
            return Snapshot(epoch, status, tx, rx, data)
        return None

    def _command(self, kind, index, write_value, snap, now, **extra):
        if self.pending is not None:
            raise MailboxError('overlapping CSR command')
        # Publish software ownership BEFORE the store. I/O exceptions poison
        # the adapter: retrying an ambiguously completed store is not safe.
        self.pending = dict(kind=kind, before=snap, time=now, **extra)
        self._write(index, write_value)
        return 'pending'

    def _reset_observation(self, snap, now):
        if snap.generation < self.generation:
            raise MailboxError('fabric reset/generation rollback while owned')
        new_reset = snap.generation != self.generation or (snap.status & RESET and not self.in_reset)
        if new_reset:
            self.reset_write_race = self.reset_write_race or self.pending is not None
            self.pending = self.flight = None
            self._mouse.reset()
            self.tx_sequence = self.rx_sequence = 0
            self.armed = False
            self.generation = snap.generation
            self.epoch_time = now
        self.in_reset = bool(snap.status & RESET)
        if self.in_reset:
            if snap.status & ~(RESET | EXHAUSTED) or snap.tx or snap.rx:
                raise MailboxError('guest reset did not clear mailbox ownership')
            return True
        return False

    def _confirm(self, snap, now):
        p = self.pending
        before, kind = p['before'], p['kind']
        if now - p['time'] > self.timeout:
            raise MailboxError('CSR command did not obtain a confirmed outcome')
        if kind == 'clear':
            if snap.status & p['bits']:
                return 'pending'
            self.pending = None
            return 'flags_acknowledged'
        if kind == 'submit':
            if snap.tx == before.tx + 1:
                if snap.status & ERROR or not snap.status & TX_STATE:
                    raise MailboxError('admitted TX lost ownership or has protocol error')
                token, value = self._mouse.admitted()
                if value != p['value']:
                    raise MailboxError('offered mouse byte changed before admission')
                self.tx_sequence = snap.tx
                self.flight = (token, snap.tx)
                self.pending = None
                return 'tx_admitted'
            if snap.tx != before.tx:
                raise MailboxError('TX admission sequence skipped or rolled back')
            if snap.status & ERROR:
                # READY is advisory. A just-arriving RX/abort can reject this
                # sole writer's store. No sequence advance means no admission.
                # Clear only this newly generated, explained write rejection;
                # pre-existing errors never enter this path.
                if snap.status & TX_STATE or not snap.status & (RX_FULL | RX_ABORT):
                    raise MailboxError('unexplained TX submission rejection')
                self.pending = None
                return self._command('clear', 10, 2, snap, now, bits=ERROR)
            return 'pending'
        if snap.status & ERROR:
            raise MailboxError('unexpected CSR/protocol error')
        if kind == 'arm':
            if not snap.status & ARMED:
                return 'pending'
            self.armed = True
            self.reset_write_race = False
            result = 'armed'
        elif kind == 'ack_tx':
            if snap.tx != before.tx:
                raise MailboxError('TX sequence changed during event acknowledgement')
            if snap.status & EVENT:
                if bool(snap.status & DELIVERED) != p['delivered']:
                    raise MailboxError('retained TX event changed')
                return 'pending'
            if snap.status & (QUEUED | ACTIVE):
                raise MailboxError('foreign TX while acknowledging our event')
            self._mouse.completed(self.flight[0], delivered=p['delivered'])
            self.flight = None
            result = 'tx_delivered' if p['delivered'] else 'tx_aborted'
        elif kind == 'ack_rx':
            if snap.rx == before.rx and snap.status & RX_FULL:
                if snap.data != before.data:
                    raise MailboxError('retained RX changed before acknowledgement')
                return 'pending'
            if not (snap.rx == before.rx and not snap.status & RX_FULL or
                    snap.rx == before.rx + 1 and snap.status & RX_FULL):
                raise MailboxError('RX acknowledgement lost a command')
            self._mouse.receive(before.data & 255, errors=before.data >> 8)
            self.rx_sequence = before.rx
            result = 'rx_received'
        else:
            raise MailboxError('unknown pending operation')
        self.pending = None
        return result

    def poll(self, now_ns):
        if self.failed is not None:
            raise MailboxError('adapter poisoned: '+self.failed)
        if type(now_ns) is not int or now_ns < 0 or now_ns < self.last_time:
            raise ValueError('monotonic integer nanoseconds required')
        self.last_time = now_ns
        try:
            return self._poll(now_ns)
        except Exception as error:
            self.failed = str(error)
            raise

    def _poll(self, now):
        snap = self._snapshot()
        if snap is None:
            # Even an unstable snapshot must not defeat the command deadline.
            if self.pending and now - self.pending['time'] > self.timeout:
                raise MailboxError('unstable CSR state exceeded command deadline')
            return 'retry'
        if self._reset_observation(snap, now):
            return 'reset'
        if self.pending is not None:
            return self._confirm(snap, now)
        if snap.status & ERROR:
            if not self.armed and self.reset_write_race:
                return self._command('clear', 10, 2, snap, now, bits=ERROR)
            raise MailboxError('pre-existing mailbox protocol error')
        if not self.armed:
            if snap.status & (ARMED | TX_STATE) or snap.tx:
                raise MailboxError('foreign ownership before arm')
            if snap.status & EXHAUSTED:
                return 'needs_reset'
            return self._command('arm', 3, self.generation, snap, now)
        if not snap.status & ARMED or snap.tx != self.tx_sequence:
            raise MailboxError('unexplained loss/change of mailbox ownership')
        if self.flight is not None:
            if snap.status & EVENT:
                return self._command('ack_tx', 6, self.flight[1], snap, now,
                                     delivered=bool(snap.status & DELIVERED))
            if not snap.status & (QUEUED | ACTIVE):
                raise MailboxError('owned TX disappeared without an event/reset')
            return 'waiting_tx'
        if snap.status & TX_STATE:
            raise MailboxError('unowned TX event or byte')
        if snap.status & RX_FULL:
            if snap.rx != self.rx_sequence + 1:
                raise MailboxError('unexpected RX sequence')
            return self._command('ack_rx', 9, snap.rx, snap, now)
        if snap.rx != self.rx_sequence:
            raise MailboxError('RX disappeared without acknowledgement/reset')
        if snap.status & RX_ABORT:
            return self._command('clear', 10, 1, snap, now, bits=RX_ABORT)
        if snap.status & EXHAUSTED:
            return 'needs_reset'
        self._mouse.advance(now - self.epoch_time)
        value = self._mouse.peek()
        if value is None or not snap.status & READY:
            return 'idle'
        return self._command('submit', 4, value, snap, now, value=value)

    def input(self, dx=0, dy=0, buttons=None):
        """Sensor counts only. Producer must backpressure until the device arms."""
        if self.failed is not None or not self.armed or self.in_reset:
            raise MailboxError('mouse input requires an owned running device')
        self._mouse.input(dx, dy, buttons)
