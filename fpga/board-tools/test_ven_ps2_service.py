"""Native Unix-socket tests; fake MMIO, not FPGA/Windows qualification."""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import socket
import tempfile
import time
import unittest
from unittest.mock import patch

import ven_ps2_service as service
from test_ven_ps2_mailbox_host import Registers
from ven_ps2_mailbox_host import Adapter


class ServiceTests(unittest.TestCase):
    def setUp(self):
        scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
        self.assertEqual(scratch, Path('/home/yukidama/external/tmp').resolve(strict=True))
        self.temporary = tempfile.TemporaryDirectory(prefix='ps2-service-unit.', dir=scratch)
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name)/'mouse.sock'
        self.reg = Registers()
        self.host = Adapter(self.reg.read, self.reg.write)

    def armed(self):
        self.reg.reset = False
        self.host.poll(0); self.host.poll(1)
        self.assertTrue(self.host.armed)

    def endpoint(self):
        endpoint = service.Endpoint(self.path, self.host)
        self.addCleanup(endpoint.close)
        return endpoint

    def client(self, endpoint):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.addCleanup(client.close)
        client.settimeout(0.1)
        client.connect(str(self.path))
        endpoint.step(0)
        return client

    def test_input_requires_arm_and_reports_queue_not_delivery(self):
        request = b'{"op":"input","dx":20,"dy":-12,"buttons":1}'
        self.assertFalse(service.response(self.host, request)['ok'])
        self.armed()
        result = service.response(self.host, request)
        self.assertEqual(result, dict(ok=True, queued=True, delivery_confirmed=False))
        self.assertEqual((self.host._mouse.dx, self.host._mouse.dy, self.host._mouse.buttons), (20, -12, 1))
        self.assertEqual(self.reg.writes, [(3, 0)])  # No immediate TX/MMIO side effect.

    def test_invalid_requests_leave_policy_unchanged(self):
        self.armed()
        requests = [b'null', b'[]', b'\xff', b'{', b'x'*513,
            b'{"op":"status","dx":1}', b'{"op":"reset"}', b'{"op":"input"}',
            b'{"op":"input","dx":true}', b'{"op":"input","dx":1.0}',
            b'{"op":"input","dx":32768}', b'{"op":"input","dy":-32768}',
            b'{"op":"input","buttons":8}', b'{"op":"input","buttons":null}',
            b'{"op":"input","buttons":false}', b'{"op":"input","eip":0}']
        for request in requests:
            with self.subTest(request=request):
                self.assertFalse(service.response(self.host, request)['ok'])
                self.assertEqual((self.host._mouse.dx, self.host._mouse.dy, self.host._mouse.buttons), (0, 0, 0))

    def test_status_is_read_only_and_not_a_delivery_fence(self):
        result = service.response(self.host, b'{"op":"status"}')
        self.assertFalse(result['armed'])
        self.assertFalse(result['delivery_confirmed'])
        self.assertEqual(self.reg.writes, [])

    def test_native_seqpacket_input_and_single_request_connection(self):
        self.armed()
        endpoint = self.endpoint()
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        client = self.client(endpoint)
        client.sendall(b'{"op":"input","dx":23}')
        endpoint.step(0); endpoint.step(0)
        self.assertTrue(json.loads(client.recv(1024))['queued'])
        self.assertEqual(client.recv(1024), b'')
        self.assertEqual(self.host._mouse.dx, 23)
        self.assertFalse(endpoint.clients)

    def test_oversized_packet_cannot_be_parsed_as_partial_request(self):
        self.armed()
        endpoint = self.endpoint()
        client = self.client(endpoint)
        client.sendall(b'{"op":"input","dx":1}'+b' '*600)
        endpoint.step(0); endpoint.step(0)
        self.assertFalse(json.loads(client.recv(1024))['ok'])
        self.assertEqual(self.host._mouse.dx, 0)

    def test_idle_clients_are_bounded_nonblocking_and_expire(self):
        endpoint = self.endpoint()
        clients = [self.client(endpoint) for _ in range(5)]
        self.assertEqual(len(endpoint.clients), 4)
        self.assertEqual(clients[-1].recv(1024), b'')
        start = time.monotonic()
        for _ in range(20): endpoint.step(0)
        self.assertLess(time.monotonic()-start, 0.5)
        with patch.object(service.time, 'monotonic', return_value=start+2):
            endpoint.step(0)
        self.assertFalse(endpoint.clients)

    def test_existing_endpoint_refused_without_removing_owner(self):
        endpoint = self.endpoint()
        identity = self.path.stat().st_ino
        with self.assertRaises(OSError): service.Endpoint(self.path, self.host)
        self.assertEqual(self.path.stat().st_ino, identity)
        client = self.client(endpoint)
        client.sendall(b'{"op":"status"}')
        endpoint.step(0); endpoint.step(0)
        self.assertTrue(json.loads(client.recv(1024))['ok'])

    def test_cleanup_preserves_replaced_path(self):
        endpoint = self.endpoint()
        self.path.unlink()
        self.path.write_bytes(b'not our socket')
        endpoint.close()
        self.assertEqual(self.path.read_bytes(), b'not our socket')

    def test_serve_lifecycle_stops_without_guest_reset(self):
        handles = {}
        reg = self.reg
        closed = []
        class FakeIO:
            read32 = staticmethod(reg.read)
            write32 = staticmethod(reg.write)
            def __enter__(self): return self
            def __exit__(self, *_): closed.append('mmio')
        class FakeEndpoint:
            count = 0
            def __init__(self, _path, _host): pass
            def step(self):
                self.count += 1
                reg.reset = False  # External cold launcher, not the service.
                if self.count == 5: handles[signal.SIGTERM](signal.SIGTERM, None)
            def close(self): closed.append('endpoint')
        def install(number, handler):
            previous = handles.get(number, signal.SIG_DFL)
            handles[number] = handler
            return previous
        output = io.StringIO()
        with patch.object(service, 'MMIO', return_value=FakeIO()), \
             patch.object(service, 'Endpoint', FakeEndpoint), \
             patch.object(service.signal, 'signal', side_effect=install), \
             contextlib.redirect_stdout(output):
            service.serve(self.path)
        self.assertEqual(closed, ['endpoint', 'mmio'])
        self.assertEqual(handles, {signal.SIGTERM:signal.SIG_DFL, signal.SIGINT:signal.SIG_DFL})
        logs = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(logs[0]['event'], 'attached_held_reset')
        self.assertEqual(logs[-1]['event'], 'stopped')
        self.assertFalse(logs[-1]['guest_reset_written'])
        self.assertTrue(logs[-1]['fresh_attach_requires_reset'])
        self.assertTrue(all(index in (3, 4, 6, 9, 10) for index,_ in reg.writes))


if __name__ == '__main__':
    unittest.main()
