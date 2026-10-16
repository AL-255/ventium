from pathlib import Path
import ast
import re
import unittest

import prepare_prime_width_payload as recipe
import run_branch_address_shape as original
import run_prime_width_payload as runner

SOURCE = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/sfetch-boundary-soc-r1/source/rtl/core')


class Width(unittest.TestCase):
    def test_source_guard_and_authority_unchanged(self):
        text = (SOURCE/'core_mem_chain.svh').read_text()
        changed = recipe.transform(text)
        for name in ('mem_next_req','mem_next_commit','mc_prime_offer','mc_offer',
                     'mc_query_seg','mc_query_ea'):
            self.assertEqual(original.assignment(text,name),original.assignment(changed,name))
        self.assertEqual(re.findall(r'assign mc_prime_base = .*?;',text,re.S),
                         re.findall(r'assign mc_prime_base = .*?;',changed,re.S))
        self.assertEqual(original.raw_descriptor(text),original.raw_descriptor(changed))
        self.assertIn('assert (mc_prepare_ok === prime_width_old_prepare)',changed)
        self.assertIn('if (mem_next_req)',changed)
        self.assertEqual(recipe.prepare_block(changed).count('mc_address_payload.w8'),3)
        self.assertNotIn('mc_query_u.w8',recipe.prepare_block(changed))
        self.assertIn('mc_u_q.w8',recipe.strobe_block(changed))
        self.assertIn('agi_prime_select',recipe.strobe_block(changed))
        self.assertIn('ref_prime_select',recipe.strobe_block(changed))
        for bad in (text+'\n',changed):
            with self.assertRaises(ValueError): recipe.transform(bad)

    def test_native_fixture_has_real_width_checks_and_mutants(self):
        positive=runner.fixture(SOURCE)
        for token in ('PRIME-WIDTH-OK','PRIME_WIDTH_STROBE_MISMATCH',
                      'PRIME_WIDTH_FP64_ADMISSION_CHANGED','ic_res_buffered_end',
                      'mc_query_u.fp_sti[0]','agi_prime_width','ref_prime_strb'):
            self.assertIn(token,positive)
        for mode in runner.MODES[1:]:
            other=runner.fixture(SOURCE,mode)
            self.assertNotEqual(positive,other)
            self.assertEqual(original.raw_descriptor(positive),original.raw_descriptor(other))

    def test_whole_core_build_keeps_original_guards(self):
        import build_prime_width_core as build
        text=build.adapted_main(); ast.parse(text)
        for token in ('pass_fds=(9,)','MemoryMax=10G','MemorySwapMax=2G',
                      "len(files) == 195","== 153", "'VL_J=32'", "'--assert'",
                      "'pgrep', '-x', 'vivado'", "'tb_prime_width_'",
                      "(leaf/'core_mem_chain.svh')",'native.common.relocate'):
            self.assertIn(token,text)

    def test_functional_adapters_keep_complete_existing_comparisons(self):
        import run_prime_width_func as run
        import audit_prime_width_func as audit
        text=run.derive(); ast.parse(text)
        self.assertIn('Path(template.__file__)',text)
        self.assertIn('PARENT=PARENT,template=template)',text)
        self.assertIn("'for n in [recipe.FILE]:'",text)
        text=audit.derive(); ast.parse(text)
        self.assertIn('prime-width-core-r1',text)
        self.assertIn('prime-width-func-r2',text)
        self.assertIn('import run_prime_width_func as runner',text)

    def test_eight_corpora_preserve_coverage_and_comparisons(self):
        import run_prime_width_core as core
        text=core.derive(); ast.parse(text)
        for token in ('pass_fds=(9,)', "== 'ipc_parallel32'", "'--workers','8'",
                      "assert result['probe_runs'] == 4240", 'clocks=21190336',
                      'prime=282808,intent=5616,request=3072,accept=1872,shape_only=1536',
                      'assert native.returncode == 0', "assert checked['passed']",
                      "started['definitions'] == parent_start['definitions']",
                      'recipe.transform', 'prime_width_equality_assertion=True'):
            self.assertIn(token,text)
        for label in ('load-store','held','branch','integer','fp','agi','ref','agi-store'):
            self.assertIn("('"+label+"',",text)

    def test_parent_counter_audit_rejects_every_changed_field(self):
        import audit_prime_width_core as audit
        good='NEXT-PAIR-PROBE '+' '.join(k+'='+str(i) for i,k in enumerate(audit.FIELDS))
        self.assertEqual(audit.probe_pair(good,good),dict(zip(audit.FIELDS,range(9))))
        for i,k in enumerate(audit.FIELDS):
            with self.assertRaises(AssertionError):
                audit.probe_pair(good,good.replace(k+'='+str(i),k+'='+str(i+1)))
        for bad in ('',good+'\n'+good):
            with self.assertRaises(AssertionError): audit.probe_pair(good,bad)

    def test_native_receipt_schemas_are_explicit(self):
        import audit_prime_width_core as audit
        for label in audit.LABELS:
            key='exit' if label in ('agi','ref') else 'native_exit'
            self.assertEqual(audit.native_code({key:133},label),133)
            self.assertEqual(audit.native_code({key:1},label),1)
            for bad in ({},{key:'133'},{key:133,'other':0}):
                with self.assertRaises(AssertionError): audit.native_code(bad,label)

    def test_full_trace_comparison_rejects_state_and_length_changes(self):
        import audit_prime_width_core as audit
        from types import SimpleNamespace
        from unittest.mock import patch
        def trace(rows):return SimpleNamespace(mode='func',sys=True,x87=False,records=rows)
        good=trace([dict(n=0,eax='0x00000001')])
        for bad in (trace([dict(n=0,eax='0x00000002')]),trace([]),trace([dict(n=1,eax='0x00000001')])):
            with patch.object(audit.tracefmt,'read_trace',side_effect=[good,bad]):
                with self.assertRaises(AssertionError): audit.compare_pair('old','new')


if __name__ == '__main__': unittest.main()
