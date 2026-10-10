#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('recipe', HERE/'prepare-prefix66-system.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class TestRecipe(unittest.TestCase):
    def setUp(self):
        self.original = (HERE.parents[1]/r.TARGET).read_text()

    def test_only_context_and_owner_change(self):
        changed = r.transform(self.original)
        restored = changed.replace(r.NEW, r.OLD)
        restored = restored.replace('p54_prefix66_owner_pc', 'eip')
        self.assertEqual(restored, self.original)
        for guard in ('!fp_dbg_active', '!dbg_step_active', '!smm_active', '!v86',
                      'p54_prefix66_cancel', '!p54_prefix66_live', 'exec_flush_all',
                      'icsnp_v1 || icsnp_v2', 'smi_take || nmi_take || intr_take',
                      'p54_prefix66_external_snoop', 'pipe_int_commit'):
            self.assertIn(guard, changed)

    def test_bad_anchors(self):
        for bad in (self.original.replace(r.OLD, ''), self.original+r.OLD,
                    self.original.replace('p54_prefix66_pc_q<=eip;', ''),
                    r.transform(self.original)):
            with self.assertRaises(ValueError):
                r.transform(bad)

    def test_no_overwrite(self):
        with tempfile.TemporaryDirectory(prefix='prefix66-recipe-') as temp:
            root = Path(temp)
            # Test fixtures are created through the recipe's exclusive writer.
            source = HERE.parents[1]/r.TARGET
            out = root/'candidate.svh'
            r.prepare(source, out)
            with self.assertRaises(FileExistsError):
                r.prepare(source, out)
            with self.assertRaises(ValueError):
                r.prepare(source, source)


if __name__ == '__main__':
    unittest.main()
