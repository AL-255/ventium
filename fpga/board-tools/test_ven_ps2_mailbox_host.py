"""Software-adapter/CSR model tests, NOT RTL, native MMIO or FPGA qualification."""
import unittest

import ven_ps2_mailbox_host as host


class Registers:
    """Independent transaction-level model of the documented mailbox contract."""
    def __init__(self):
        self.cap = host.CAPABILITY
        self.generation = 0
        self.reset = True
        self.armed = self.error = self.rx_abort = self.exhausted = False
        self.tx = self.rx = 0
        self.tx_state = self.data = self.rx_data = 0
        self.delivered = False
        self.rx_full = False
        self.writes = []
        self.before_write = None
        self.after_write = None
        self.on_read = None
        self.deferred = []
        self.defer = False
        self.ignore = False

    def status(self):
        ready = self.armed and not (self.reset or self.error or self.tx_state or self.rx_full or
                                   self.tx == host.MASK32)
        return ((host.RESET if self.reset else 0) | (host.ARMED if self.armed else 0) |
                (host.READY if ready else 0) | self.tx_state |
                (host.DELIVERED if self.delivered and self.tx_state == host.EVENT else 0) |
                (host.RX_FULL if self.rx_full else 0) | (host.RX_ABORT if self.rx_abort else 0) |
                (host.ERROR if self.error else 0) |
                (host.EXHAUSTED if self.exhausted or max(self.tx, self.rx) == host.MASK32 else 0))

    def read(self, address):
        if self.on_read:
            self.on_read(address)
        return {0:self.cap, 1:self.status(), 2:self.generation, 5:self.tx,
                7:self.rx_data, 8:self.rx}.get(address, 0)

    def write(self, address, value):
        self.writes.append((address, value))
        if self.before_write:
            hook, self.before_write = self.before_write, None
            hook(address, value)
        if self.defer:
            self.deferred.append((address, value))
        elif not self.ignore:
            self.apply(address, value)
        if self.after_write:
            hook, self.after_write = self.after_write, None
            hook(address, value)

    def apply(self, address, value):
        if self.reset:
            return
        if address == 3 and value == self.generation and not self.tx_state:
            self.armed = True
        elif address == 4 and self.status() & host.READY and 0 <= value <= 255:
            self.tx += 1
            self.data = value
            self.tx_state = host.QUEUED
            self.delivered = False
        elif address == 6 and self.armed and self.tx_state == host.EVENT and value == self.tx:
            self.tx_state = 0
        elif address == 9 and self.armed and self.rx_full and value == self.rx:
            self.rx_full = False
        elif address == 10 and value <= 3:
            if value & 1: self.rx_abort = False
            if value & 2: self.error = False
        else:
            self.error = True

    def flush(self):
        pending, self.deferred = self.deferred, []
        for address, value in pending:
            self.apply(address, value)

    def receive(self, byte, errors=0):
        assert not self.rx_full and self.rx < host.MASK32
        self.rx += 1
        self.rx_data = byte | (errors << 8)
        self.rx_full = True
        if self.tx_state in (host.QUEUED, host.ACTIVE):
            self.complete(False)

    def complete(self, delivered=True):
        assert self.tx_state in (host.QUEUED, host.ACTIVE)
        self.tx_state = host.EVENT
        self.delivered = delivered

    def guest_reset(self, *, release=False):
        self.generation += 1
        self.reset = not release
        self.armed = self.error = self.rx_full = self.rx_abort = False
        self.tx = self.rx = self.tx_state = 0
        self.delivered = False


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.reg = Registers()
        self.adapter = host.Adapter(self.reg.read, self.reg.write, command_timeout_ns=100)
        self.now = 0

    def poll(self):
        self.now += 1
        return self.adapter.poll(self.now)

    def arm(self):
        self.reg.reset = False
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.reg.writes[-1], (3, self.reg.generation))
        self.assertEqual(self.poll(), 'armed')

    def tx(self, byte, delivered=True):
        self.assertEqual(self.poll(), 'pending')
        self.assertIsNone(self.adapter.flight)
        self.assertEqual(self.reg.data, byte)
        self.assertEqual(self.poll(), 'tx_admitted')
        self.assertIsNotNone(self.adapter.flight)
        self.reg.complete(delivered)
        self.assertEqual(self.poll(), 'pending')
        self.assertIsNotNone(self.adapter.flight)
        self.assertEqual(self.poll(), 'tx_delivered' if delivered else 'tx_aborted')
        self.assertIsNone(self.adapter.flight)

    def ready(self):
        self.arm()
        self.tx(0xaa)
        self.tx(0)

    def receive(self, value, errors=0):
        self.reg.receive(value, errors)
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.reg.writes[-1], (9, self.reg.rx))
        self.assertEqual(self.poll(), 'rx_received')

    def test_attach_requires_known_reset_and_capability_no_writes(self):
        for change in ('capability', 'running', 'owned', 'sequence'):
            r = Registers()
            if change == 'capability': r.cap = 0
            if change == 'running': r.reset = False
            if change == 'owned': r.armed = True
            if change == 'sequence': r.tx = 1
            with self.subTest(change=change), self.assertRaises(host.MailboxError):
                host.Adapter(r.read, r.write)
            self.assertEqual(r.writes, [])

    def test_bat_and_real_host_commands_and_motion(self):
        self.ready()
        self.receive(0xf2); self.tx(0xfa); self.tx(0)
        self.receive(0xf4); self.tx(0xfa)
        self.adapter.input(20, -12, 1)
        self.now = 10_000_100
        for byte in (0x29, 20, 244): self.tx(byte)
        self.assertEqual((self.adapter._mouse.dx, self.adapter._mouse.dy), (0, 0))
        self.receive(0xfe)
        for byte in (0x29, 20, 244): self.tx(byte)
        self.assertEqual((self.adapter._mouse.dx, self.adapter._mouse.dy), (0, 0))

    def test_submission_waits_for_sequence_and_store_is_not_repeated(self):
        self.arm()
        self.reg.defer = True
        self.assertEqual(self.poll(), 'pending')
        stores = len(self.reg.writes)
        for _ in range(5): self.assertEqual(self.poll(), 'pending')
        self.assertIsNone(self.adapter.flight)
        self.assertEqual(len(self.reg.writes), stores)
        self.reg.flush()
        self.assertEqual(self.poll(), 'tx_admitted')

    def test_immediate_delivery_before_admission_readback(self):
        self.arm()
        self.reg.after_write = lambda _a, _v: self.reg.complete()
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.poll(), 'tx_admitted')
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.poll(), 'tx_delivered')
        self.assertEqual(self.adapter._mouse.peek(), 0)

    def test_tx_abort_is_resolved_before_command_and_no_replayed_suffix(self):
        self.arm()
        self.poll(); self.poll()  # BAT owns the wire.
        self.reg.receive(0xf2)
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.reg.writes[-1][0], 6)
        self.assertEqual(self.poll(), 'tx_aborted')
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.reg.writes[-1][0], 9)
        self.assertEqual(self.poll(), 'rx_received')
        self.tx(0xfa); self.tx(0)

    def test_ready_rx_race_rejects_without_false_admission(self):
        self.arm()
        self.reg.before_write = lambda _a, _v: self.reg.receive(0xf2)
        self.assertEqual(self.poll(), 'pending')
        self.assertTrue(self.reg.error)
        self.assertEqual(self.reg.tx, 0)
        self.assertEqual(self.poll(), 'pending')  # Precisely explained W1C.
        self.assertEqual(self.reg.writes[-1], (10, 2))
        self.assertEqual(self.poll(), 'flags_acknowledged')
        self.assertIsNone(self.adapter.flight)
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.poll(), 'rx_received')
        self.tx(0xfa); self.tx(0)

    def test_preexisting_error_never_cleared_and_poison_blocks_writes(self):
        self.arm(); self.reg.error = True
        before = list(self.reg.writes)
        with self.assertRaisesRegex(host.MailboxError, 'pre-existing'): self.poll()
        with self.assertRaisesRegex(host.MailboxError, 'poisoned'): self.poll()
        self.assertEqual(self.reg.writes, before)

    def test_sticky_rx_abort_can_coexist_with_ready_and_is_acknowledged(self):
        self.ready(); self.reg.rx_abort = True
        self.assertTrue(self.reg.status() & host.READY)
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.reg.writes[-1], (10, 1))
        self.assertEqual(self.poll(), 'flags_acknowledged')

    def test_back_to_back_rx_while_ack_readback_is_pending(self):
        self.ready()
        self.reg.receive(0xf3)
        self.reg.after_write = lambda _a, _v: self.reg.receive(200)
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.poll(), 'rx_received')
        self.assertEqual(self.adapter._mouse.parameter, 0xf3)
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.poll(), 'rx_received')
        self.assertEqual(self.adapter._mouse.rate, 200)
        self.tx(0xfa)

    def test_receive_error_requests_resend_not_command_execution(self):
        self.ready(); self.receive(0xf4, 1); self.tx(0xfe)
        self.assertFalse(self.adapter._mouse.enabled)

    def test_reset_drops_owned_packet_and_observed_short_reset_rearms(self):
        self.arm(); self.poll(); self.poll()
        token = self.adapter.flight[0]
        self.reg.guest_reset(release=True)
        self.assertEqual(self.poll(), 'pending')
        self.assertIsNone(self.adapter.flight)
        self.assertEqual(self.poll(), 'armed')
        self.assertEqual(self.adapter.tx_sequence, 0)
        self.poll(); self.poll()
        self.assertNotEqual(self.adapter.flight[0], token)

    def test_delayed_stale_ack_after_reset_is_not_policy_commit(self):
        self.arm(); self.poll(); self.poll(); self.reg.complete()
        self.reg.defer = True
        self.assertEqual(self.poll(), 'pending')
        self.reg.guest_reset(release=True)
        self.reg.flush()  # Old event ACK rejected by the disarmed new epoch.
        self.reg.defer = False
        self.assertTrue(self.reg.error)
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.reg.writes[-1], (10, 2))
        self.assertIsNone(self.adapter.flight)
        self.assertEqual(self.poll(), 'flags_acknowledged')
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.poll(), 'armed')
        self.tx(0xaa); self.tx(0)

    def test_reset_during_submit_does_not_admit_old_byte(self):
        self.arm()
        self.reg.before_write = lambda _a, _v: self.reg.guest_reset(release=True)
        self.poll()
        self.assertEqual(self.reg.tx, 0)
        self.assertEqual(self.poll(), 'pending')
        self.assertIsNone(self.adapter.flight)
        self.assertEqual(self.poll(), 'flags_acknowledged')
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.poll(), 'armed')

    def test_repeated_reset_retains_knowledge_of_old_posted_write(self):
        self.arm(); self.poll(); self.poll(); self.reg.complete()
        self.reg.defer = True
        self.assertEqual(self.poll(), 'pending')
        self.reg.guest_reset()
        self.assertEqual(self.poll(), 'reset')
        self.reg.reset = False
        self.reg.guest_reset()
        self.assertEqual(self.poll(), 'reset')
        self.reg.reset = False
        self.reg.flush()
        self.reg.defer = False
        self.assertTrue(self.reg.error)
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.reg.writes[-1], (10, 2))
        self.assertEqual(self.poll(), 'flags_acknowledged')
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.poll(), 'armed')
        self.tx(0xaa); self.tx(0)

    def test_coherent_read_retries_generation_change(self):
        self.ready()
        fired = False
        def change(address):
            nonlocal fired
            if address == 5 and not fired:
                fired = True
                self.reg.guest_reset(release=True)
        self.reg.on_read = change
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.adapter.generation, 1)
        self.assertEqual(self.poll(), 'armed')

    def test_reset_at_each_read_of_snapshot_never_commits_old_command(self):
        for boundary in range(1, 8):
            with self.subTest(boundary=boundary):
                self.setUp(); self.ready(); self.reg.receive(0xf4)
                count = 0
                def reset_on_read(_address):
                    nonlocal count
                    count += 1
                    if count == boundary:
                        self.reg.guest_reset(release=True)
                self.reg.on_read = reset_on_read
                self.assertEqual(self.poll(), 'pending')
                self.assertFalse(self.adapter._mouse.enabled)
                self.assertEqual(self.reg.writes[-1], (3, 1))
                self.assertEqual(self.poll(), 'armed')

    def test_retained_rx_corruption_and_event_corruption_fail(self):
        self.ready(); self.reg.receive(0xf4); self.reg.defer = True
        self.poll(); self.reg.rx_data = 0xf5
        with self.assertRaisesRegex(host.MailboxError, 'retained RX'): self.poll()
        self.setUp(); self.arm(); self.poll(); self.poll(); self.reg.complete()
        self.reg.defer = True; self.poll(); self.reg.delivered = False
        with self.assertRaisesRegex(host.MailboxError, 'retained TX'): self.poll()

    def test_unstable_read_cannot_defeat_pending_command_deadline(self):
        self.arm(); self.reg.defer = True; self.poll()
        def unstable(address):
            if address == 1: self.reg.rx_abort = not self.reg.rx_abort
        self.reg.on_read = unstable
        self.assertEqual(self.poll(), 'retry')
        self.now += 101
        with self.assertRaisesRegex(host.MailboxError, 'unstable CSR'): self.poll()

    def test_final_counter_event_can_complete_before_reset_requirement(self):
        self.ready()
        self.reg.tx = self.adapter.tx_sequence = host.MASK32 - 1
        self.receive(0xf4)
        self.tx(0xfa)
        self.assertEqual(self.reg.tx, host.MASK32)
        self.assertEqual(self.poll(), 'needs_reset')

    def test_command_timeout_stops_ambiguous_store_without_retry(self):
        self.arm(); self.reg.ignore = True; self.poll()
        before = list(self.reg.writes)
        self.now += 101
        with self.assertRaisesRegex(host.MailboxError, 'confirmed outcome'): self.poll()
        self.assertEqual(self.reg.writes, before)

    def test_io_failure_poisons_ambiguous_store(self):
        def failed_write(_a, _v): raise OSError('test MMIO failure')
        self.adapter._write = failed_write
        self.reg.reset = False
        with self.assertRaises(OSError): self.poll()
        with self.assertRaisesRegex(host.MailboxError, 'poisoned'): self.poll()

    def test_foreign_sequence_and_missing_event_are_fatal(self):
        for change in ('sequence', 'missing', 'unowned'):
            self.setUp(); self.arm()
            if change != 'unowned': self.poll(); self.poll()
            if change == 'sequence': self.reg.tx += 1
            if change == 'missing': self.reg.tx_state = 0
            if change == 'unowned': self.reg.tx_state = host.EVENT
            with self.subTest(change=change), self.assertRaises(host.MailboxError): self.poll()

    def test_generation_rollback_and_invalid_words_fail_closed(self):
        self.reg.guest_reset(); self.poll(); self.reg.generation = 0
        with self.assertRaisesRegex(host.MailboxError, 'rollback'): self.poll()
        self.setUp(); self.reg.read = lambda _a: False
        with self.assertRaisesRegex(host.MailboxError, '32-bit'):
            host.Adapter(self.reg.read, self.reg.write)

    def test_counter_exhaustion_is_not_wrapped_or_guest_reset(self):
        self.ready()
        self.reg.rx = self.adapter.rx_sequence = host.MASK32
        self.assertTrue(self.reg.status() & host.READY)
        before = list(self.reg.writes)
        self.assertEqual(self.poll(), 'needs_reset')
        self.assertEqual(self.reg.writes, before)
        self.reg.guest_reset(release=True)
        self.assertEqual(self.poll(), 'pending')
        self.assertEqual(self.poll(), 'armed')

    def test_input_admission_and_monotonic_time(self):
        with self.assertRaises(host.MailboxError): self.adapter.input(1)
        with self.assertRaises(ValueError): self.adapter.poll(True)
        self.poll()
        with self.assertRaises(ValueError): self.adapter.poll(0)
        self.assertEqual(self.reg.writes, [])


if __name__ == '__main__':
    unittest.main()
