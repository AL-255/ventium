"""Check exact two-file directed-core, PC and FPGA byte correspondence."""
import os
from pathlib import Path
import unittest

import build_intent_ready_soc as native
import freeze_intent_ready_rk_candidate as freeze

ROOT = Path(os.environ.get('INTENT_READY_ROOT',
    '/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI')).resolve(strict=True)


class TransferTests(unittest.TestCase):
    def test_exact_two_file_delta(self):
        self.assertEqual(native.CHANGES, ['rtl/mem/ven_l1d.sv','rtl/mem/ventium_l1_axi.sv'])
        for name in native.CHANGES:
            with self.subTest(name=name):
                before = (ROOT/'fresh-pair-soc-r1/source'/name).read_bytes()
                after = (ROOT/'intent-ready-core-r1/candidate'/name).read_bytes()
                self.assertEqual(native.recipe.transform(before.decode(),name).encode(),after)
                self.assertTrue(freeze.check_delta('ventium/'+name,before,after))
                for bad in (before, after+b'\n'):
                    with self.assertRaises(Exception):
                        freeze.check_delta('ventium/'+name,before,bad)
                for bad in (before+b'\n', after):
                    with self.assertRaises(ValueError):
                        native.recipe.transform(bad.decode(),name)

    def test_unrelated_payload_unchanged(self):
        name='ventium/rtl/core/core.sv'
        self.assertFalse(freeze.check_delta(name,b'unchanged',b'unchanged'))
        with self.assertRaises(Exception):
            freeze.check_delta(name,b'unchanged',b'changed')

    def test_build_keeps_native_source_closure_and_harness_checks(self):
        original = native.original.read_text()
        for start,end in [('def regressions(', '\ndef prepare('),
                          ('    shared=', '    host='),
                          ('    command=', '    for p in (*files,')]:
            self.assertEqual(original.split(start)[1].split(end)[0],
                             native.text.split(start)[1].split(end)[0])
        self.assertIn('return base.build(root)', native.text)


if __name__ == '__main__': unittest.main()
