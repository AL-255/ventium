"""Check the private processor builders retain source and verification guards."""
import unittest
from unittest.mock import patch

import audit_qualified_pair_credit_core as audit
import build_qualified_pair_credit_core as build
import run_qualified_pair_credit_core as run


class Processor(unittest.TestCase):
    def test_build_retains_exact_closure_and_private_host(self):
        text = build.adapted_main()
        compile(text, build.__file__, 'exec')
        for token in ("len(files) == 195", "len(set(definitions)) == 153",
                      "native.sha(p) == old['pins'][str(p)]", "'tb_qualified_pair_credit_'",
                      "shutil.disk_usage(scratch).free > 5*1024**3", "pass_fds=(9,)",
                      "native.build(root)", "[str(p.relative_to(root/'candidate'))",
                      "== CHANGES", "leaf/Path(n).name"):
            self.assertIn(token, text)
        self.assertEqual(build.CHANGES, ['rtl/mem/ven_axi_master.sv', 'rtl/mem/ventium_l1_axi.sv'])

    def test_system_oracle_modes_and_comparison_unchanged(self):
        text = run.adapted_main()
        compile(text, run.__file__, 'exec')
        for token in ("start['changes'] == CHANGES", "for latency in (0,7,31)",
                      "('cycle-func','cycle')", "'--l1-axi'", "'--system','--cosim'",
                      "compare.compare_func(gold,tr,False,0xffffffff,False,20,f,sys_both=True)",
                      "traces['parent']!=traces['candidate']", "result['candidate_v_retirements']>0",
                      "len(CASES)*12", "native_affinity_observed"):
            self.assertIn(token, text)
        self.assertNotIn('+ven_system_read_ack_witness', text)
        self.assertNotIn('all_read_owners_exercised', text)
        self.assertEqual(len(run.CPUS), len(run.previous.CASES))
        self.assertFalse(set(run.CPUS) & {0, 1, 2, 3, 6, 10, 11, 14})

    def test_auditor_requires_reaped_owner_and_exact_exit(self):
        def check(pid='0', status='0', result='success', invocation='abc'):
            output = f'MainPID={pid}\nInvocationID={invocation}\nResult={result}\nExecMainStatus={status}\n'
            with patch.object(audit.subprocess, 'check_output', return_value=output):
                return audit.owner('unit.service', 'abc', 0)
        self.assertEqual(check()['MainPID'], '0')
        for wrong in (dict(pid='123'), dict(status='1'), dict(result='exit-code'), dict(invocation='other')):
            with self.assertRaises(AssertionError):
                check(**wrong)

    def test_failed_canonical_owner_not_relabeled_success(self):
        output = 'MainPID=0\nInvocationID=abc\nResult=exit-code\nExecMainStatus=1\n'
        with patch.object(audit.subprocess, 'check_output', return_value=output):
            self.assertEqual(audit.owner('unit.service', 'abc', 1)['Result'], 'exit-code')
            with self.assertRaises(AssertionError):
                audit.owner('unit.service', 'abc', 0)


if __name__ == '__main__':
    unittest.main()
