#!/usr/bin/env python3
"""Post-queue fixture generation must preserve its source and fail on drift."""
import importlib.util
from pathlib import Path
import threading
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('event', HERE/'prepare-fp-mem64-event.py')
event = importlib.util.module_from_spec(spec)
spec.loader.exec_module(event)
spec = importlib.util.spec_from_file_location('driver', HERE/'run-fp-mem64-queue.py')
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class EventFixture(unittest.TestCase):
    def test_event_setup_and_drift(self):
        source = (HERE/'fp-mem64-queue.S').read_text()
        generated = event.transform(source)
        self.assertEqual(generated.count('event_handler:\n'), 1)
        self.assertEqual(generated.count('movl $0x001063,0x12004'), 1)
        self.assertIn('    int3\n', generated)
        self.assertIn('    movw %dx,%ds\n', generated)
        self.assertIn('cmpl $source_op,0x8f24c', generated)
        self.assertIn('movzwl 0x8f244,%eax', generated)
        self.assertNotIn('fstl 0x8f2a0', generated)
        self.assertNotIn('fldenv 0x8f240', generated)
        for text in ('', source+source, generated, source.replace('integer_end:', 'missing:')):
            with self.subTest(text=text[:30]), self.assertRaises(ValueError):
                event.transform(text)
        self.assertEqual((HERE/'fp-mem64-queue.S').read_text(), source)

    def test_port_reuse_is_rejected(self):
        class Socket:
            def __init__(self, port):
                self.port = port
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def bind(self, address):
                assert address == ('127.0.0.1', 0)
            def getsockname(self):
                return ('127.0.0.1', self.port)
        used = set()
        lock = threading.Lock()
        with patch.object(driver.socket, 'socket', side_effect=[Socket(p) for p in (31000,31000,31001)]):
            self.assertEqual(driver.unique_port(used, lock), 31000)
            self.assertEqual(driver.unique_port(used, lock), 31001)
        self.assertEqual(used, {31000,31001})
        with patch.object(driver.socket, 'socket', side_effect=lambda: Socket(31000)):
            with self.assertRaises(RuntimeError):
                driver.unique_port(used, lock)


if __name__ == '__main__':
    unittest.main()
