#!/usr/bin/env python3
"""Private recipe fail-closed tests, not RTL behavior/performance acceptance."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('prepare',HERE/'prepare-held-read-prime.py')
prepare=importlib.util.module_from_spec(spec);spec.loader.exec_module(prepare)
# Minimal distinct anchors. The real-source compiled/leaf/differential gates
# are separate; these tests check bounded text transformation and copy safety.
ANCHORS=[
    '`ifdef VEN_RAW_V_READ_PRIME\n`ifdef VEN_UOPCACHE',
    '      return d;\n    end\n  endfunction\n`else',
    'assign mc_prime_base = mc_fp_self_prime || (',
    'assert (!mc_valid_q && !mc_chain_accept && !pipe_mem_active_q &&',
    "mc_query_pc == (mc_fp_self_prime ? eip : eip + {28'd0, u_d.len})",
    '    end else if (ven_fetchdbg_en)\n      $display("[FETCHDBG:RAWPRIME]',
    '            !pipe_mem_active_q && !pipe_new_mem_req &&',
]
TEXT='\n// independent anchor\n'.join(ANCHORS)
class Guards(unittest.TestCase):
    def test_reject_every_missing_and_duplicate_anchor(self):
        for anchor in ANCHORS:
            with self.subTest(anchor=anchor):
                for text in (TEXT.replace(anchor,''),TEXT+'\n'+anchor):
                    with self.assertRaises(ValueError):prepare.transform(text)
    def test_reject_reapplication(self):
        with self.assertRaises(ValueError):prepare.transform(prepare.transform(TEXT))
    def test_only_named_admission_changes(self):
        before=TEXT+'\n// preserved ownership guards\nmc_prepare_ok = CHECK_ALL;\nmem_next_commit = pipe_int_commit;\n'
        after=prepare.transform(before)
        self.assertIn('mc_prepare_ok = CHECK_ALL;\nmem_next_commit = pipe_int_commit;',after)
        self.assertIn('pc == pipe_mem_eip_q + {28\'d0, pipe_mem_u_q.len}',after)
        self.assertIn('d = pipe_mem_v_q;',after)
        self.assertIn('mc_fresh_read_prime',after)
        self.assertIn('`ifndef VEN_RAW_V_READ_PRIME',after)
        self.assertIn('`ifndef VEN_PIPE_MEM_CHAIN',after)
    def test_copy_delta_and_nested_rejection(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as d:
            root=Path(d);source=root/'source';source.mkdir()
            p=source/'rtl/core/core_mem_chain.svh';p.parent.mkdir(parents=True);p.write_text(TEXT)
            (source/'keep.txt').write_text('unchanged\n')
            with self.assertRaises(ValueError):prepare.prepare(source,source/'nested')
            self.assertFalse((source/'nested').exists())
            output=root/'candidate';receipt=prepare.prepare(source,output)
            self.assertEqual(p.read_text(),TEXT)
            self.assertEqual((output/'keep.txt').read_text(),'unchanged\n')
            self.assertEqual([p for p,h in receipt['parent_pins'].items()
                              if h!=receipt['candidate_pins'][p]],['rtl/core/core_mem_chain.svh'])
            self.assertEqual(set(receipt['candidate_pins'])-set(receipt['parent_pins']),
                             {'rtl/core/core_raw_held_prime.svh'})
            self.assertFalse(receipt['production']);self.assertFalse(receipt['standard_suite'])
            self.assertIsNone(receipt['gameplay_ipc'])
    def test_existing_output_not_overwritten(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as d:
            root=Path(d);source=root/'source';p=source/'rtl/core/core_mem_chain.svh'
            p.parent.mkdir(parents=True);p.write_text(TEXT)
            output=root/'out';output.mkdir();sentinel=output/'keep';sentinel.write_text('keep')
            with self.assertRaises(FileExistsError):prepare.prepare(source,output)
            self.assertEqual(sentinel.read_text(),'keep')
if __name__=='__main__':unittest.main()
