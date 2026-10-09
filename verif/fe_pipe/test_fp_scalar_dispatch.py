#!/usr/bin/env python3
"""Fail-closed private transformation tests; not RTL/performance acceptance."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('prepare', HERE/'prepare-fp-scalar-dispatch.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
TEXT = prepare.ANCHOR + '\n// retained packet capture\n' + prepare.TAIL


class Guards(unittest.TestCase):
    def test_missing_and_duplicate_anchors(self):
        for anchor in (prepare.ANCHOR, prepare.TAIL):
            for text in (TEXT.replace(anchor, ''), TEXT+'\n'+anchor):
                with self.subTest(anchor=anchor, text=text):
                    with self.assertRaises(ValueError):
                        prepare.transform(text)

    def test_reapplication_rejected(self):
        with self.assertRaises(ValueError):
            prepare.transform(prepare.transform(TEXT))

    def test_no_new_command_or_retirement(self):
        transformed = prepare.transform(TEXT)
        self.assertEqual(transformed.count('capture_reference_decode(eip);'), 1)
        self.assertEqual(transformed.count('state <= S_FLOAD;'), 1)
        self.assertIn('state <= d_mem_read ? S_LOAD : S_EXEC;', transformed)
        self.assertIn('// retained packet capture', transformed)
        self.assertNotIn('fp_cmd_valid <=', transformed)
        self.assertNotIn('mem_req <=', transformed)
        self.assertNotIn('retire <=', transformed)

    def test_copy_delta_and_nested_rejection(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as folder:
            root = Path(folder)
            source = root/'source'
            p = source/'rtl/core/core.sv'
            p.parent.mkdir(parents=True)
            p.write_text(TEXT)
            (source/'keep').write_text('unchanged')
            with self.assertRaises(ValueError):
                prepare.prepare(source, source/'nested')
            self.assertFalse((source/'nested').exists())
            output = root/'candidate'
            result = prepare.prepare(source, output)
            self.assertEqual(p.read_text(), TEXT)
            self.assertEqual((output/'keep').read_text(), 'unchanged')
            self.assertEqual([p for p,h in result['parent_pins'].items()
                              if h != result['candidate_pins'][p]], ['rtl/core/core.sv'])
            self.assertEqual(set(result['candidate_pins'])-set(result['parent_pins']),
                             {'rtl/core/core_fp_scalar_dispatch.svh'})
            self.assertFalse(result['production'])
            self.assertFalse(result['standard_suite'])
            self.assertIsNone(result['gameplay_ipc'])

    def test_existing_output_preserved(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as folder:
            root = Path(folder)
            source = root/'source'
            p = source/'rtl/core/core.sv'
            p.parent.mkdir(parents=True)
            p.write_text(TEXT)
            output = root/'candidate'
            output.mkdir()
            (output/'keep').write_text('keep')
            with self.assertRaises(FileExistsError):
                prepare.prepare(source, output)
            self.assertEqual((output/'keep').read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
