"""Fail closed on architecture, timing-policy, definition or adapter drift."""
import ast
import copy
from pathlib import Path
import unittest

import build_sfetch_boundary_soc as builder
import run_sfetch_boundary_coremark as runner
import audit_sfetch_boundary_coremark as auditor


class DiagnosticTransfer(unittest.TestCase):
    def test_adapters_compile_and_keep_failure(self):
        for source in (builder.prepare_source(),builder.build_source()): ast.parse(source)
        self.assertIn("assert not checked['canonical_gate_passed']",builder.build_source())
        self.assertIn('DIAGNOSTIC cost experiment',builder.prepare_source())

    def test_cycle_policy_rejects_new_drift(self):
        old=[dict(n=i,pc=hex(i),cyc=74+i,pipe='U',paired=False) for i in range(4603)]
        old[-1]['cyc']=30125
        new=copy.deepcopy(old)
        for row in new[1:]: row['cyc']+=21
        name='mb_brrandom.cycle_rtl.vtrace'
        self.assertEqual(builder.check_cycle_records(name,old,new)['added_clocks'],21)
        for key,value in (('pc','0xdead'),('pipe','V'),('paired',True),('cyc',100000)):
            bad=copy.deepcopy(new);bad[200][key]=value
            with self.assertRaises(AssertionError): builder.check_cycle_records(name,old,bad)
        with self.assertRaises(AssertionError): builder.check_cycle_records('mb_agi.cycle_rtl.vtrace',old,new)
        with self.assertRaises(AssertionError): builder.check_cycle_records(name,old,new[:-1])

    def test_original_definitions_remain_required(self):
        self.assertEqual(builder.CHANGES,['rtl/core/core.sv','rtl/core/core_fetch_decode.svh'])
        command=builder.load(runner.PARENT/'build-started.json')['command']
        defs=(runner.PARENT/'defines.txt').read_text().splitlines()
        self.assertEqual(len(builder.previous.check_definitions(command,defs)),157)
        for name in ('VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTLOAD_FLAT'):
            bad=[s for s in command if s not in ('-D'+name,'+define+'+name)]
            with self.assertRaises(AssertionError): builder.previous.check_definitions(bad,defs)

    def test_cost_reporting_and_unchanged_acceptance(self):
        for source in (runner.derive(),auditor.derive()): ast.parse(source)
        self.assertIn("require_valid_duration=False",runner.derive())
        self.assertIn("assert result['crcs']==reference['crcs']",runner.derive())
        self.assertIn('actual_wait=True',runner.derive())
        self.assertIn("assert owner['Result'] == 'success'",auditor.derive())
        for seed,ticks in runner.TICKS.items():
            self.assertEqual(runner.cost(seed,ticks)['added_clocks'],0)
            self.assertAlmostEqual(runner.cost(seed,ticks*2)['throughput_gain_percent'],-50)
            self.assertAlmostEqual(runner.cost(seed,ticks*2)['clock_cost_percent'],100)
            with self.assertRaises(AssertionError): runner.cost(seed,0)


if __name__=='__main__': unittest.main()
