"""Host-only checks; no native guest, desktop verdict or FPGA access."""
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

import prepare_fp_repair_win95 as p


class Win95PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        template = p.q.PARENT / 'run_win95_cold.py'
        assert p.sha(template) == p.q.TEMPLATES['run_win95_cold.py']
        cls.original = template.read_text()
        cls.code = p.derive(cls.original, p.q.SCRATCH / 'fixture', {})
        cls.runner = types.ModuleType('win95_repair_fixture')
        exec(compile(cls.code, '<fixture>', 'exec'), cls.runner.__dict__)

    def test_native_command_and_environment_unchanged(self):
        old = types.ModuleType('parent_fixture')
        exec(compile(self.original, '<parent>', 'exec'), old.__dict__)
        path = Path('/nonexecuted/fixture')
        self.assertEqual(self.runner.command(path), old.command(path))
        self.assertEqual(self.runner.clean_environment(path), old.clean_environment(path))

    def test_resource_constraints_are_exact(self):
        values = {'cpu.max': '100000 100000', 'memory.max': str(2*1024**3),
                  'memory.swap.max': '0', 'pids.max': '160',
                  'memory.events': 'oom 0\noom_kill 0\noom_group_kill 0',
                  'memory.events.local': 'oom 0\noom_kill 0\noom_group_kill 0'}
        self.runner.validate_limits(values, [10], 4*1024**3)
        for key, value in (('pids.max', '32'), ('pids.max', '161'), ('memory.swap.max', '1')):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.runner.validate_limits(values | {key: value}, [10], 4*1024**3)
        with self.assertRaises(ValueError):
            self.runner.validate_limits(values, [10, 11], 4*1024**3)

    def test_host_closure_never_awards_desktop_pass(self):
        result = dict(terminal_error=None, errors=[], native_exit_code=0,
                      stop_reason=None, closed_engine_log={'finished': True})
        self.assertEqual(self.runner.classify(result), 'CLOSED_UNQUALIFIED')
        self.assertEqual(self.runner.classify(result | {'stop_reason': 'disk reserve'}), 'INCOMPLETE')
        self.assertEqual(self.runner.classify(result | {'terminal_error': 'Invalid VxD'}), 'FAIL')

    def test_live_disk_floor_requests_owned_stop(self):
        class Process:
            pid = 7654321
            stdout = None
            def __init__(self): self.polls = 0
            def poll(self):
                self.polls += 1
                return None if self.polls == 1 else 0
            def wait(self, **_kw): return 0
        class Capture:
            eof = False
            def start(self, _stream): pass
            def finish(self, **_kw): return b'closed\n'
            def snapshot(self): pass
            def receipt(self, **kw): return kw
        helper = types.SimpleNamespace(PIPE_EXIT_GRACE=1,
            require_process_group_absent=lambda pid: None,
            gate=types.SimpleNamespace(check_closed_log=lambda data: {'closed': True}))
        with tempfile.TemporaryDirectory() as tmp:
            stop = Path(tmp) / 'stop.request'
            with patch.object(self.runner.subprocess, 'Popen', return_value=Process()), \
                 patch.object(self.runner.FatalScanner, 'observe'), \
                 patch.object(self.runner.time, 'sleep'), \
                 patch.object(self.runner.shutil, 'disk_usage', return_value=types.SimpleNamespace(free=4*1024**3-1)):
                result = self.runner.collect([], {}, helper, Capture(), stop, lambda proc: {'pid': proc.pid})
            self.assertTrue(stop.is_file())
            self.assertTrue(result['actual_child_wait'])
            self.assertIn('disk reserve', result['stop_reason'])
            self.assertEqual(self.runner.classify(result), 'INCOMPLETE')


if __name__ == '__main__':
    unittest.main()
