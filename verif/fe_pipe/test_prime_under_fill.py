#!/usr/bin/env python3
"""Generator guards; native leaf/full-core gates remain required."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
spec=importlib.util.spec_from_file_location('under_fill',HERE/'prepare-prime-under-fill.py')
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)


class Guards(unittest.TestCase):
    def test_preserves_capture_payload_and_response_rules(self):
        before=(REPO/'rtl/mem/ven_l1d.sv').read_text()
        after=mod.transform(before)
        for fragment in ('c_next_req && !c_req && !rd_armed',
                         '!early_armed && !stream_path',
                         'assign c_next_ready =', 'assign mc_capture_next =',
                         'assign do_rd_cap =', 'rd_window_q <= rd_window;',
                         'rd_addr_q   <= lookup_addr;',
                         '(rd_match && !flush_all && !snoop_inv_valid'):
            self.assertEqual(before.count(fragment),after.count(fragment))
        self.assertIn('(c_next_addr[OFFW +: IDXW] != fset)',after)
        self.assertIn('!bypass_q && !fill_poison',after)
        self.assertIn('!code_fill_q &&',after)
        self.assertIn('VEN_L1D_HIT_UNDER_FILL',after)

    def test_reapplication_is_rejected(self):
        source=(REPO/'rtl/mem/ven_l1d.sv').read_text()
        with self.assertRaises(ValueError):mod.transform(mod.transform(source))

    def test_anchor_drift_is_rejected(self):
        source=(REPO/'rtl/mem/ven_l1d.sv').read_text()
        with self.assertRaises(ValueError):mod.transform(source.replace('      unique case (st)','      case (st)'))
        with self.assertRaises(ValueError):mod.transform(source+source)

    def test_single_leaf_and_nested_output_guard(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            root=Path(directory);source=root/'source'
            leaf=source/'rtl/mem/ven_l1d.sv';leaf.parent.mkdir(parents=True)
            leaf.write_text((REPO/'rtl/mem/ven_l1d.sv').read_text())
            (source/'other').write_text('keep\n')
            result=mod.prepare(source,root/'candidate')
            self.assertEqual([p for p,h in result['parent_pins'].items()
                              if h!=result['candidate_pins'][p]],['rtl/mem/ven_l1d.sv'])
            self.assertIsNone(result['gameplay_ipc'])
            self.assertFalse(result['standard_suite'])
            with self.assertRaises(ValueError):mod.prepare(source,source/'nested')


if __name__=='__main__':unittest.main()
