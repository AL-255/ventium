#!/usr/bin/env python3
"""Fail-closed source recipes; not architectural/performance acceptance."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, HERE/(name+'.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


wide = module('prepare-fp-mem64-queue')
dptr = module('prepare-fp-dptr-offset')


class Recipes(unittest.TestCase):
    def test_wide_reapplication_and_source_drift(self):
        for name, transform in ((wide.CORE, wide.core), (wide.QUEUE, wide.queue)):
            text = (REPO/name).read_text()
            changed = transform(text)
            self.assertNotEqual(text, changed)
            with self.assertRaises(ValueError):
                transform(changed)
            with self.assertRaises(ValueError):
                transform(text+text)
            with self.assertRaises(ValueError):
                transform('')

    def test_both_load_owner_lists(self):
        text = (REPO/wide.CORE).read_text()
        anchor = '(fp_async_cmd_op == FX_FILD_M32)))'
        self.assertEqual(text.count(anchor), 2)
        with self.assertRaises(ValueError):
            wide.core(text.replace(anchor, '(fp_async_cmd_op == FX_NONE)))', 1))
        result = wide.core(text)
        self.assertEqual(result.count('(fp_async_cmd_op == FX_FILD_M64)'), 2)

    def test_wide_copy_only_two_files(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as folder:
            root = Path(folder)
            source = root/'source'
            for name in (wide.CORE, wide.QUEUE):
                p = source/name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text((REPO/name).read_text())
            (source/'retained').write_text('untouched')
            with self.assertRaises(ValueError):
                wide.prepare(source, source/'nested')
            self.assertFalse((source/'nested').exists())
            result = wide.prepare(source, root/'candidate')
            self.assertEqual({p for p,h in result['parent_pins'].items() if h != result['candidate_pins'][p]},
                             {wide.CORE, wide.QUEUE})
            self.assertEqual((root/'candidate/retained').read_text(), 'untouched')
            with self.assertRaises(FileExistsError):
                wide.prepare(source, root/'candidate')

    def test_pointer_anchor(self):
        source = 'before\n'+dptr.OLD+'\nafter'
        fixed = dptr.transform(source)
        self.assertEqual(fixed, 'before\n'+dptr.NEW+'\nafter')
        for bad in ('', source+source, fixed):
            with self.assertRaises(ValueError):
                dptr.transform(bad)
        self.assertIn('seg_real ? (dbase + q_ea) : q_ea', fixed)

    def test_pointer_copy_and_preservation(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as folder:
            root = Path(folder)
            source = root/'source'
            p = source/dptr.NAME
            p.parent.mkdir(parents=True)
            p.write_text(dptr.OLD)
            with self.assertRaises(ValueError):
                dptr.prepare(source, source/'nested')
            result = dptr.prepare(source, root/'candidate')
            self.assertEqual(p.read_text(), dptr.OLD)
            self.assertEqual(set(result['candidate_pins']), {dptr.NAME})
            self.assertFalse(result['production'])
            self.assertFalse(result['standard_suite'])
            self.assertIsNone(result['gameplay_ipc'])
            with self.assertRaises(FileExistsError):
                dptr.prepare(source, root/'candidate')


if __name__ == '__main__':
    unittest.main()
