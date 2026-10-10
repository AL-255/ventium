"""Protocol-only tests: not CSR, wire, guest-driver or physical FPGA coverage."""
import unittest

from ven_ps2_mouse import Mouse


class MouseTests(unittest.TestCase):
    def drain(self, mouse):
        data = []
        while mouse.peek() is not None:
            self.assertLess(len(data), 8, 'unbounded response')
            token, value = mouse.admitted()
            self.assertIsNone(mouse.peek())
            data.append(value)
            mouse.completed(token, delivered=True)
        return data

    def make(self):
        mouse = Mouse()
        self.assertEqual(self.drain(mouse), [0xAA, 0])
        return mouse

    def command(self, mouse, byte, expected=(0xFA,), **kwargs):
        mouse.receive(byte, **kwargs)
        self.assertEqual(self.drain(mouse), list(expected))

    def test_reset_defaults_identification_and_no_false_wheel(self):
        m = self.make()
        self.command(m, 0xFF, [0xFA, 0xAA, 0])
        self.command(m, 0xE9, [0xFA, 0, 2, 100])
        for rate in (200, 100, 80, 200, 200, 80):
            self.command(m, 0xF3)
            self.command(m, rate)
        self.command(m, 0xF2, [0xFA, 0])
        self.command(m, 0xF6)
        self.command(m, 0xE9, [0xFA, 0, 2, 100])

    def test_parameters_and_framing_errors(self):
        for command, valid, invalid, attr in ((0xF3, Mouse.RATES, 7, 'rate'),
                                             (0xE8, range(4), 4, 'resolution')):
            for value in valid:
                with self.subTest(command=command, value=value):
                    m = self.make()
                    self.command(m, command)
                    old = getattr(m, attr)
                    for flags in (1, 2, 3):
                        self.command(m, value, [0xFE], errors=flags)
                        self.assertEqual(getattr(m, attr), old)
                        self.assertEqual(m.parameter, command)
                    self.command(m, invalid, [0xFE])
                    self.command(m, value)
                    self.assertEqual(getattr(m, attr), value)
                    self.assertIsNone(m.parameter)
        m = self.make()
        self.command(m, 0xF3)
        self.command(m, 0, [0xFE])
        self.command(m, 0, [0xFC])
        self.assertIsNone(m.parameter)
        self.command(m, 0xFF, [0xFA, 0xAA, 0])

    def test_wrap_echo_and_restore_mode(self):
        for remote in (False, True):
            m = self.make()
            if remote:
                self.command(m, 0xF0)
            self.command(m, 0xEE)
            for value in range(256):
                if value not in (0xEC, 0xFF):
                    self.command(m, value, [value])
            self.command(m, 0xEC)
            self.assertEqual(m.remote, remote)
            self.assertFalse(m.wrap)
            self.command(m, 0xEE)
            self.command(m, 0xFF, [0xFA, 0xAA, 0])
            self.assertFalse(m.wrap or m.remote or m.enabled)

    def test_wrap_does_not_lose_physical_button_release(self):
        m = self.make()
        self.command(m, 0xF4)
        m.input(buttons=1)
        m.advance(10_000_000)
        self.assertEqual(self.drain(m), [9, 0, 0])
        self.command(m, 0xEE)
        m.input(5, 8, 0)
        self.command(m, 0xEC)
        m.advance(20_000_000)
        self.assertEqual(self.drain(m), [8, 0, 0])

    def test_status_button_mapping_and_packet_signs(self):
        for buttons in range(8):
            m = self.make()
            self.command(m, 0xF0)
            self.command(m, 0xF4)
            self.command(m, 0xE7)
            m.input(buttons=buttons)
            status_buttons = [0, 4, 1, 5, 2, 6, 3, 7][buttons]
            self.command(m, 0xE9, [0xFA, 0x70 | status_buttons, 2, 100])
            for x in (-255, -128, -1, 0, 1, 128, 255):
                for y in (-255, -128, -1, 0, 1, 128, 255):
                    m.input(x, y)
                    self.command(m, 0xEB, [0xFA, 8 | buttons | (16 if x < 0 else 0)
                                          | (32 if y < 0 else 0), x & 255, y & 255])
                    self.assertEqual((m.dx, m.dy), (0, 0))

    def test_stream_pacing_disable_remote_and_button_release(self):
        m = self.make()
        m.input(4, -6, 1)
        m.advance(1_000_000_000)
        self.assertIsNone(m.peek())
        # Disabled reporting still permits explicit polling.
        self.command(m, 0xEB, [0xFA, 0x29, 4, 250])
        self.command(m, 0xF4)
        m.input(2, 3)
        m.advance(1_009_999_999)
        self.assertIsNone(m.peek())
        m.advance(1_010_000_000)
        self.assertEqual(self.drain(m), [9, 2, 3])
        m.input(buttons=0)
        m.advance(1_020_000_000)
        self.assertEqual(self.drain(m), [8, 0, 0])
        m.advance(2_000_000_000)
        self.assertIsNone(m.peek())
        self.command(m, 0xF0)
        m.input(1)
        m.advance(3_000_000_000)
        self.assertIsNone(m.peek())
        self.command(m, 0xEB, [0xFA, 8, 1, 0])
        self.command(m, 0xEA)
        self.command(m, 0xF5)
        m.input(2)
        m.advance(4_000_000_000)
        self.assertIsNone(m.peek())

    def test_scaling_table_and_remote_poll_unscaled(self):
        for sign in (-1, 1):
            for raw, scaled in enumerate((0, 1, 1, 3, 6, 9, 12, 14)):
                m = self.make()
                self.command(m, 0xF4)
                self.command(m, 0xE7)
                m.input(sign * raw, sign * raw, 1)
                m.advance(10_000_000)
                header = 9 | (0x30 if sign < 0 and scaled else 0)
                self.assertEqual(self.drain(m), [header, (sign * scaled) & 255,
                                                (sign * scaled) & 255])
                m.input(sign * raw)
                self.command(m, 0xEB, [0xFA, 9 | (16 if sign < 0 and raw else 0),
                                      (sign * raw) & 255, 0])

    def test_resend_whole_packet_and_no_double_motion_consumption(self):
        m = self.make()
        m.input(7, -8)
        self.command(m, 0xEB, [0xFA, 0x28, 7, 248])
        for _ in range(3):
            self.command(m, 0xFE, [0x28, 7, 248])
            self.assertEqual((m.dx, m.dy), (0, 0))
        self.command(m, 0xFF, [0xFA, 0xAA, 0])
        self.command(m, 0xFE, [0xAA, 0])
        self.command(m, 0xF4)
        self.command(m, 0xFE)
        self.command(m, 0x00, [0xFE])
        self.command(m, 0xFE)  # Don't recursively resend device's FE request.

    def test_inhibit_every_packet_byte_restarts_and_counts_once(self):
        for prefix in range(3):
            m = self.make()
            self.command(m, 0xF4)
            m.input(12, -13)
            m.advance(10_000_000)
            for _ in range(prefix):
                token, _ = m.admitted()
                m.completed(token, delivered=True)
            token, _ = m.admitted()
            m.completed(token, delivered=False)
            self.assertEqual((m.dx, m.dy), (12, -13))
            m.input(3, 4)
            self.assertEqual(self.drain(m), [0x28, 12, 243])
            self.assertEqual((m.dx, m.dy), (3, 4))

    def test_partial_resend_and_command_preemption(self):
        m = self.make()
        self.command(m, 0xF4)
        m.input(6, -7)
        m.advance(10_000_000)
        token, _ = m.admitted()
        m.completed(token, delivered=True)
        token, _ = m.admitted()
        m.completed(token, delivered=False)
        self.command(m, 0xFE, [0x28, 6, 249])
        self.assertEqual((m.dx, m.dy), (0, 0))
        m.input(8, 9)
        m.advance(20_000_000)
        token, _ = m.admitted()
        with self.assertRaises(RuntimeError):
            m.receive(0xFF)
        m.completed(token, delivered=False)
        self.command(m, 0xFF, [0xFA, 0xAA, 0])
        self.assertEqual((m.dx, m.dy), (0, 0))

    def test_large_delta_partition_and_samples_arriving_during_delivery(self):
        for scaling, bound in ((False, 255), (True, 127)):
            m = self.make()
            self.command(m, 0xF4)
            if scaling:
                self.command(m, 0xE7)
            m.input(1000, -1000)
            raw = 1000
            for n in range(1, 20):
                m.advance(n * 10_000_000)
                if raw == 0:
                    self.assertIsNone(m.peek())
                    break
                chunk = min(raw, bound)
                output = chunk * 2 if scaling else chunk
                self.assertEqual(self.drain(m), [0x28, output & 255, -output & 255])
                raw -= chunk
                self.assertEqual((m.dx, m.dy), (raw, -raw))
            self.assertEqual(raw, 0)

    def test_ownership_reset_duplicate_and_unadmitted_resend(self):
        m = Mouse()
        m.receive(0xFE)
        self.assertEqual(self.drain(m), [0xFE])  # BAT never delivered.
        m.receive(0xF2)
        token, value = m.admitted()
        self.assertEqual(value, 0xFA)
        with self.assertRaises(RuntimeError):
            m.admitted()
        m.reset()
        new, _ = m.admitted()
        self.assertNotEqual(new, token)
        with self.assertRaises(RuntimeError):
            m.completed(token, delivered=True)
        m.completed(new, delivered=True)
        with self.assertRaises(RuntimeError):
            m.completed(new, delivered=True)
        self.assertEqual(self.drain(m), [0])

    def test_invalid_api_and_backpressure_are_atomic(self):
        m = self.make()
        m.input(Mouse.MAX_PENDING, 0, 1)
        with self.assertRaises(OverflowError):
            m.input(1, 0, 0)
        self.assertEqual((m.dx, m.dy, m.buttons), (Mouse.MAX_PENDING, 0, 1))
        for args in ((1.0, 0, 0), (0, 0, 8)):
            with self.assertRaises(ValueError):
                m.input(*args)
        m.advance(100)
        with self.assertRaises(ValueError):
            m.advance(99)
        with self.assertRaises(ValueError):
            m.receive(256)

    def test_backlog_bound_includes_inflight_commit(self):
        m = self.make()
        self.command(m, 0xF4)
        m.input(255, -255)
        m.advance(10_000_000)
        for dx, dy in ((-Mouse.MAX_PENDING-255, 0), (0, Mouse.MAX_PENDING+255)):
            with self.assertRaises(OverflowError):
                m.input(dx, dy, 1)
            self.assertEqual((m.dx, m.dy, m.buttons), (255, -255, 0))
        m.input(-Mouse.MAX_PENDING, Mouse.MAX_PENDING)
        self.assertEqual(self.drain(m), [0x28, 255, 1])
        self.assertEqual((m.dx, m.dy), (-Mouse.MAX_PENDING, Mouse.MAX_PENDING))


if __name__ == '__main__':
    unittest.main()
