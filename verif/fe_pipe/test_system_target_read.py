#!/usr/bin/env python3
"""Fail-closed target-steering recipe and default-off source identity."""
import importlib.util
from pathlib import Path
import re
import unittest

here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('recipe', here / 'prepare-system-target-read.py')
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)


class Recipe(unittest.TestCase):
    def setUp(self):
        self.source = (here.parents[1] / 'rtl/core/core_ctrl_target_read.svh').read_text()

    def test_default_off_identity(self):
        changed = recipe.transform(self.source)
        active, selected = [True], []
        for line in changed.splitlines():
            if line == '`ifdef ' + recipe.FLAG:
                active.append(False)
            elif len(active) > 1 and line == '`else':
                active[-1] = not active[-1]
            elif len(active) > 1 and line == '`endif':
                active.pop()
            elif all(active):
                selected.append(line)
        self.assertEqual(active, [True])
        self.assertEqual(re.sub(r'\s+', '', '\n'.join(selected)), re.sub(r'\s+', '', self.source))

    def test_reject_drift_and_reapplication(self):
        for source in ('', self.source+self.source, self.source.replace('call_target;', 'flin;'),
                       recipe.transform(self.source)):
            with self.subTest(source=source[:30]), self.assertRaises(ValueError):
                recipe.transform(source)


if __name__ == '__main__':
    unittest.main()
