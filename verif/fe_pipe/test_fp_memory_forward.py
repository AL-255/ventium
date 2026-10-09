#!/usr/bin/env python3
"""Source transformation guards, not RTL correctness evidence."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('memory_forward', HERE/'prepare-fp-memory-forward.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class Guards(unittest.TestCase):
    def test_only_intended_top_change(self):
        source = (REPO/'fp_shared/ven_fp_top.sv').read_text()
        text = mod.transform(source)
        self.assertIn('issue_reads_sti && (arith_owner_dst[2] == cmd_sti)', text)
        self.assertIn('VEN_FP_ARITH_MEM_FWD requires', text)
        # Existing earlier-stage, pop, masks, ES and stack-fault interlocks stay.
        for fragment in ('!arith_owner_pop[2] && arith_stream_eligible',
                         '!cmd_pop && !issue_stack_fault',
                         "(fctrl_o[5:0] == 6'h3f) && !fstat_o[7]",
                         "&& !((i == 2) && arith_forward_eligible",
                         'arith_mul_interval_busy',
                         'alu_b = f_mem_as_float(cmd_mem, cmd_mem_bytes);',
                         'alu_b = f_mem_as_int(cmd_mem, cmd_mem_bytes);'):
            self.assertEqual(text.count(fragment), source.count(fragment))

    def test_reapplication_rejected(self):
        source = (REPO/'fp_shared/ven_fp_top.sv').read_text()
        with self.assertRaises(ValueError):
            mod.transform(mod.transform(source))

    def test_missing_or_duplicate_anchor_rejected(self):
        source = (REPO/'fp_shared/ven_fp_top.sv').read_text()
        anchor = '  wire logic accept = cmd_valid & cmd_ready;'
        for changed in (source.replace(anchor, ''), source+anchor):
            with self.assertRaises(ValueError):
                mod.transform(changed)

    def test_private_copy_and_nested_guard(self):
        with tempfile.TemporaryDirectory(prefix='ventium-fpmem-guard-', dir=os.environ['TMPDIR']) as name:
            root = Path(name)
            source = root/'source'
            (source/'fp_shared').mkdir(parents=True)
            (source/'fp_shared/ven_fp_top.sv').write_text((REPO/'fp_shared/ven_fp_top.sv').read_text())
            (source/'untouched').write_text('retain this source\n')
            result = mod.prepare(source, root/'output')
            self.assertEqual([p for p,h in result['parent_pins'].items()
                              if h != result['candidate_pins'][p]], ['fp_shared/ven_fp_top.sv'])
            self.assertIsNone(result['gameplay_ipc'])
            self.assertFalse(result['standard_suite'])
            with self.assertRaises(ValueError):
                mod.prepare(source, source/'nested')
            with self.assertRaises(FileExistsError):
                mod.prepare(source, root/'output')


if __name__ == '__main__':
    unittest.main()
