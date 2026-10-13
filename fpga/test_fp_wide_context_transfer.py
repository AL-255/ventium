"""Exact transfer deltas and unchanged native admission; not FPGA acceptance."""
import ast
import os
from pathlib import Path
import unittest

import build_fp_wide_context_soc as native
import freeze_fp_wide_context_rk_candidate as freeze
import run_fp_wide_context_regressions as regressions

ROOT = Path(os.environ.get('FP_WIDE_CONTEXT_ROOT',
    '/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI')).resolve(strict=True)


class WideContextTransfer(unittest.TestCase):
    def test_exact_four_file_delta(self):
        self.assertEqual(native.CHANGES, sorted(('rtl/core/core.sv', 'rtl/ventium_top.sv',
            'rtl/mem/ven_l1d.sv', 'rtl/mem/ventium_l1_axi.sv')))
        for name in native.CHANGES:
            before = (ROOT/'payload-region-soc-r1/source'/name).read_bytes()
            after = (ROOT/'fp-wide-context-core-r1/candidate'/name).read_bytes()
            self.assertEqual(native.recipe.transform(before.decode(), name).encode(), after)
            self.assertTrue(freeze.check_delta('ventium/'+name, before, after))
            for bad in (before, after+b'\n'):
                with self.assertRaises(Exception):
                    freeze.check_delta('ventium/'+name, before, bad)

    def test_no_other_hdl_delta_or_inherited_acceptance(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/core/core_mem_chain.svh', b'x', b'x'))
        with self.assertRaises(Exception):
            freeze.check_delta('ventium/rtl/core/core_mem_chain.svh', b'x', b'y')
        for marker in ('len(hw) == len(set(hw)) == 158', 'compiled == 170',
                       'standard_suite=False, hardware_acceptance=False', 'core_mhz=40'):
            self.assertIn(marker, freeze.text)
        self.assertIn('recipe.validate_sources', native.text)

    def test_native_pc_admission_and_build_preserved(self):
        old = native.original.read_text()
        for start, end in (('def regressions(', '\ndef prepare('),
                           ('    shared=', '    host='),
                           ('    command=', '    for p in (*files,')):
            self.assertEqual(old.split(start)[1].split(end)[0],
                             native.text.split(start)[1].split(end)[0])
        self.assertIn('return base.build(root)', native.text)

    def test_full_regression_plan_and_grading_preserved(self):
        old, new = regressions.original.read_text(), regressions.derive()
        functions = lambda text: {n.name: n for n in ast.parse(text).body
                                  if isinstance(n, ast.FunctionDef)}
        self.assertEqual(ast.dump(functions(old)['plan']), ast.dump(functions(new)['plan']))
        for key in ('commands=plan(parent,candidate,root)', 'result.update(pins_unchanged='):
            self.assertEqual(old.split(key)[1], new.split(key)[1])


if __name__ == '__main__':
    unittest.main()
