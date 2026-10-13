"""Host-only checks for the repaired candidate's existing cold Quake flow."""
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import prepare_fp_repair_cold as p


class ColdPreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        original={n:(p.PARENT/n).read_text() for n in p.TEMPLATES}
        for n,h in p.TEMPLATES.items():
            if p.sha(p.PARENT/n)!=h:raise AssertionError(n)
        cls.outputs=p.derive(original,p.SCRATCH/'fixture',{})

    def test_completion_checker_and_guest_command_unchanged(self):
        check=self.outputs['cold-helpers/check_quake_timedemo.py']
        self.assertEqual(check,(p.PARENT/'cold-helpers/check_quake_timedemo.py').read_text())
        text=self.outputs['run_quake_cold.py']
        for marker in ("result.get('result', {}).get('frames') == 969",
                       "capture.get('actual_child_wait') is True",
                       "capture.get('pipe_eof') is True", "capture.get('sticky_error') is None",
                       "inputs.get('snapshots') is False", "inputs.get('guest_modifications') is False"):
            self.assertIn(marker,text)
        helper=self.outputs['cold-helpers/run_quake_standard.py']
        self.assertIn('"--rate", "40000000"',helper)
        self.assertIn('"--mem", "16"',helper)
        self.assertIn('shutil.disk_usage(out).free < 4 * 1024**3',helper)

    def test_resource_helper_limits_and_disabled_win95_entry(self):
        guard=types.ModuleType('resource_test')
        guard.__file__='/no-execution/resource.py'
        exec(compile(self.outputs['run_win95_cold.py'],guard.__file__,'exec'),guard.__dict__)
        guard.CPU=11
        values={'cpu.max':'100000 100000','memory.max':str(2*1024**3),
                'memory.swap.max':'0','pids.max':'160',
                'memory.events':'oom 0\noom_kill 0\noom_group_kill 0',
                'memory.events.local':'oom 0\noom_kill 0\noom_group_kill 0'}
        guard.validate_limits(values,[11],4*1024**3)
        for key,value in (('pids.max','32'),('pids.max','161'),('memory.swap.max','1'),
                          ('memory.events','oom 1\noom_kill 0\noom_group_kill 0')):
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):
                guard.validate_limits(values|{key:value},[11],4*1024**3)
        with self.assertRaises(ValueError):guard.validate_limits(values,[11,12],4*1024**3)
        with patch.object(guard,'resource_receipt',side_effect=AssertionError('must not reach guard')):
            with self.assertRaisesRegex(ValueError,'Win95 launch not prepared'):guard.main()


if __name__=='__main__':unittest.main()
