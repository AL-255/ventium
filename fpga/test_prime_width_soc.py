import ast
import copy
import unittest

import build_prime_width_soc as builder
import run_prime_width_coremark as cm
import audit_prime_width_coremark as audit


class Transfer(unittest.TestCase):
    def test_only_exact_prime_width_delta_moves(self):
        before=(builder.ROOT/'sfetch-boundary-soc-r1/source'/builder.recipe.FILE).read_bytes()
        after=(builder.ROOT/'prime-width-core-r1/candidate'/builder.recipe.FILE).read_bytes()
        self.assertTrue(builder.check_delta(builder.recipe.FILE,before,after))
        self.assertFalse(builder.check_delta('unchanged',b'a',b'a'))
        with self.assertRaises(AssertionError):builder.check_delta('unchanged',b'a',b'b')
        with self.assertRaises(AssertionError):builder.check_delta(builder.recipe.FILE,before,after+b'\n')

    def test_transfer_keeps_complete_source_and_private_host_guards(self):
        text=builder.prepare_source();ast.parse(text)
        for marker in ("assert len(shared)==102",'check_delta(n,',"'sim_prime_width_'",
                       "old['directed_model']==leaf.MODEL",'check_definitions(command',
                       'Path(template.__file__)'):
            self.assertIn(marker,text)

    def test_exact_parent_audit_is_required_without_relabelling_failed_gates(self):
        audit=builder.load(builder.ROOT/'prime-width-core-checks-r1/parent-equivalence-audit.json')
        builder.check_equivalence(audit)
        for key in ('legacy_aggregate_gate_passed','canonical_gate_passed','standard_suite','hardware_acceptance'):
            bad=copy.deepcopy(audit);bad[key]=True
            with self.assertRaises(AssertionError):builder.check_equivalence(bad)
        for key in audit['totals']:
            bad=copy.deepcopy(audit);bad['totals'][key]-=1
            with self.assertRaises(AssertionError):builder.check_equivalence(bad)
        bad=copy.deepcopy(audit);bad['changed_legacy_fields']['prime']['candidate']-=1
        with self.assertRaises(AssertionError):builder.check_equivalence(bad)

    def test_parallel_native_controls_keep_crc_and_ownership_guards(self):
        text=cm.derive();ast.parse(text)
        for marker in ('max_workers=2','child.wait(timeout=600)','reference_crcs=crcs',
                       'iterations=10,require_valid_duration=False','result.update(cost(seed',
                       'actual_wait=True','proc_gone=not proc.exists()',"str(cpu)]+argv",
                       "(cg/'memory.swap.max').read_text().strip()=='0'",'Path(previous.previous.previous.__file__)'):
            self.assertIn(marker,text)
        self.assertEqual(cm.cost('performance',4771298)['added_clocks'],0)
        with self.assertRaises(AssertionError):cm.cost('performance',4771299)

    def test_native_audit_preserves_original_full_checks(self):
        text=audit.derive();ast.parse(text)
        for marker in ("native['affinity'] == [12 if seed=='performance' else 13]",
                       "ref['crcs'] == result['crcs'] == item['crcs']","native['argv'] == argv",
                       "old['ticks']==runner.TICKS[seed]",'duration_valid=False,standard_suite=False'):
            self.assertIn(marker,text)


if __name__=='__main__':unittest.main()
