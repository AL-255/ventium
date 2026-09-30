#!/usr/bin/env python3
"""Small host-only C++ gate for the generic native simulator stop predicate."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CPP = r'''
#include "sim_stop_request.h"
#include <cstdio>
int main(int argc, char **argv) {
    const auto result = ven_host::poll_sim_stop_request(argc == 1 ? nullptr : argv[1]);
    std::printf("%d %d\n", static_cast<int>(result.status), result.error);
}
'''


class StopRequestTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="ventium-stop-request.")
        cls.base = Path(cls.scratch.name)
        cls.exe = cls.base / "stop-probe"
        compiler = shlex.split(os.environ.get("CXX", "c++"))
        subprocess.run(compiler + ["-std=c++17", "-Wall", "-Wextra", "-Werror",
                       "-I", str(ROOT / "tools"), "-x", "c++", "-",
                       "-o", str(cls.exe)], input=CPP, text=True, check=True, timeout=30)

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def poll(self, path=None):
        args = [str(self.exe)] + ([] if path is None else [str(path)])
        run = subprocess.run(args, capture_output=True, text=True, check=True, timeout=5)
        return tuple(map(int, run.stdout.split()))

    def test_disabled_missing_and_empty(self):
        import errno
        self.assertEqual(self.poll(), (0, 0))
        self.assertEqual(self.poll(self.base / "missing"), (0, 0))
        self.assertEqual(self.poll(self.base / "missing-dir" / "stop"), (0, 0))
        self.assertEqual(self.poll(""), (2, errno.EINVAL))

    def test_regular_request_is_read_only(self):
        request = self.base / "request"
        request.write_bytes(b"supervisor request\n")
        before = request.stat()
        self.assertEqual(self.poll(request), (1, 0))
        self.assertEqual(request.read_bytes(), b"supervisor request\n")
        self.assertEqual(request.stat().st_mtime_ns, before.st_mtime_ns)
        empty = self.base / "empty-request"
        empty.touch()
        self.assertEqual(self.poll(empty), (1, 0))

    def test_nonregular_and_other_stat_errors_fail_closed(self):
        import errno
        self.assertEqual(self.poll(self.base), (2, errno.EINVAL))
        fifo = self.base / "request-fifo"
        os.mkfifo(fifo)
        self.assertEqual(self.poll(fifo), (2, errno.EINVAL))
        regular = self.base / "path-prefix-file"
        regular.touch()
        self.assertEqual(self.poll(regular / "stop"), (2, errno.ENOTDIR))
        loop = self.base / "loop"
        loop.symlink_to(loop.name)
        self.assertEqual(self.poll(loop), (2, errno.ELOOP))

    def test_stat_follows_symlink_but_checks_resolved_type(self):
        import errno
        regular = self.base / "link-target"
        regular.touch()
        link = self.base / "file-link"
        link.symlink_to(regular.name)
        self.assertEqual(self.poll(link), (1, 0))
        directory_link = self.base / "directory-link"
        directory_link.symlink_to(self.base, target_is_directory=True)
        self.assertEqual(self.poll(directory_link), (2, errno.EINVAL))
        broken = self.base / "broken-link"
        broken.symlink_to("absent-target")
        self.assertEqual(self.poll(broken), (0, 0))

    def test_harness_hook_remains_at_progress_boundary(self):
        source = (ROOT / "ao486-sim/ven/sim_ven.cpp").read_text()
        self.assertEqual(source.count("ven_host::poll_sim_stop_request("), 1)
        progress = source.index("if (main_time - last_report >= 500000)")
        stop = source.index("ven_host::poll_sim_stop_request(")
        retire_limit = source.index("if (g_stop_retire && g_vtm_retires >= g_stop_retire)", progress)
        self.assertLess(progress, stop)
        self.assertLess(stop, retire_limit)
        self.assertIn("top->final(); delete top; free(ddr);", source[stop:])
        self.assertIn("return stop_request_exit ? stop_request_exit", source[stop:])
        self.assertIn("if (i+1 == argc || !argv[i+1][0])", source)
        self.assertIn("host control only, not a benchmark pass", source)


if __name__ == "__main__":
    unittest.main()
