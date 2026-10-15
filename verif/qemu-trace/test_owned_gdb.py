"""No-QEMU negative transport tests; native QEMU qualification is separate."""
import ast
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import owned_gdb as owned
import gen_trace


class Checks(unittest.TestCase):
    def test_long_tmpdir_and_cleanup(self):
        with tempfile.TemporaryDirectory(prefix='long-' + 'x'*100) as directory:
            with patch.object(tempfile, 'tempdir', directory):
                endpoint = owned.OwnedGDBEndpoint()
            path = Path(endpoint.directory.name)
            try:
                self.assertTrue(path.is_relative_to(directory))
                self.assertLess(len(os.fsencode(endpoint.path)), 108)
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                    server.bind(endpoint.path)
                    self.assertTrue((path/'gdb').is_socket())
            finally:
                endpoint.close()
            self.assertFalse(path.exists())
            endpoint.close()  # idempotent

    def test_foreign_peer_rejected_without_protocol_bytes(self):
        endpoint = owned.OwnedGDBEndpoint()
        proc = subprocess.Popen(['/usr/bin/sleep', '10'])
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(endpoint.path)
                server.listen(1)
                with self.assertRaisesRegex(owned.OwnedGDBError, 'does not match'):
                    endpoint.connect(proc, 1)
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(1)
                    self.assertEqual(conn.recv(4096), b'')
                self.assertIsNone(proc.poll())
        finally:
            proc.terminate()
            proc.wait(timeout=2)
            endpoint.close()

    def test_dead_child_and_missing_socket_fail_bounded(self):
        endpoint = owned.OwnedGDBEndpoint()
        proc = subprocess.Popen(['/usr/bin/sleep', '10'])
        try:
            start = time.monotonic()
            with self.assertRaisesRegex(owned.OwnedGDBError, 'did not open'):
                endpoint.connect(proc, .05)
            self.assertLess(time.monotonic()-start, 1)
            proc.terminate()
            proc.wait(timeout=2)
            with self.assertRaisesRegex(owned.OwnedGDBError, 'exited before'):
                endpoint.connect(proc, 1)
        finally:
            gen_trace._terminate(proc)
            endpoint.close()

    def test_start_failure_cleans_private_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(tempfile, 'tempdir', directory):
                with self.assertRaises(FileNotFoundError):
                    owned.start_owned_qemu(['/nonexistent/owned-qemu', '-g', '1234'],
                                           gdb_option='-g')
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_four_managed_paths_and_replay_unchanged(self):
        tree = ast.parse(Path(gen_trace.__file__).read_text())
        expected = {'generate', 'generate_system', '_capture_initial_phys_mem',
                    'generate_syscall_proxy'}
        for node in tree.body:
            if not isinstance(node, ast.FunctionDef):
                continue
            calls = [n.func.id for n in ast.walk(node)
                     if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)]
            if node.name in expected:
                self.assertEqual(calls.count('start_owned_qemu'), 1, node.name)
                self.assertEqual(calls.count('connect_owned_qemu'), 1, node.name)
            elif node.name != '_terminate':
                self.assertNotIn('start_owned_qemu', calls, node.name)
                self.assertNotIn('connect_owned_qemu', calls, node.name)


if __name__ == '__main__':
    unittest.main()
