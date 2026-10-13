"""Run the existing host corpus on the exact 40 MHz/DDR3 cold-run derivative.

Only the platform expectation differs from the generic DDR2 fixture. No
acceptance assertion, failure detector, EOF or file-integrity check is skipped.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'tools'))
soc=Path(os.environ['FP_REPAIR_SOC']).resolve(strict=True)
receipt=json.loads((soc.parent/'cold-prepared.json').read_text())
helper=soc/'cold-helpers/run_quake_standard.py'
assert hashlib.sha256(helper.read_bytes()).hexdigest()==receipt['outputs'][str(helper)]
spec=importlib.util.spec_from_file_location('run_quake_standard',helper)
runner=importlib.util.module_from_spec(spec);sys.modules[spec.name]=runner;spec.loader.exec_module(runner)
import test_run_quake_standard as original


class BoardRunnerTest(original.RunnerTest):
    def setUp(self):
        super().setUp()
        self.args.out=self.args.out.resolve()

    def test_inherited_optional_trace_paths_never_reach_private_child(self):
        before=runner.gate.digest(self.disk)
        dangerous={'VEN_PCTRACE':str(self.disk),'VEN_PCTRACE_START':'0',
                   'VEN_PROFILE_CODE_EIP':'0','VEN_EXTRA_HOOK':str(self.disk),
                   'AO486_EXTRA_HOOK':str(self.disk),'AO486_BIOS_DIR':str(self.disk),
                   'AO486_RTC_EPOCH':'0','VTM_EXTRA_HOOK':str(self.disk),'FPGA_DDR':'0'}
        with patch.dict(os.environ,dangerous):
            code,processes,_=self.exercise({'status':'PENDING'},{'status':'PASS'})
        self.assertEqual(code,0)
        self.assertEqual(runner.gate.digest(self.disk),before)
        environment=processes[0].environment
        self.assertEqual({k for k in environment if k.startswith(('VEN_','AO486_','VTM_'))},
                         {'AO486_BIOS_DIR','AO486_RTC_EPOCH'})
        self.assertEqual(environment['AO486_BIOS_DIR'],str(self.args.out/'rom'))
        self.assertEqual(environment['AO486_RTC_EPOCH'],'1789257600')
        self.assertEqual(environment['FPGA_DDR'],'3')
        cmd=processes[0].command
        for flag,value in (('--rate','40000000'),('--rate-rtc','40000000'),('--rate-vga','80000000'),('--mem','16')):
            self.assertEqual(cmd[cmd.index(flag)+1],value)

    def test_live_disk_floor_cannot_be_overruled_by_pass(self):
        with patch.object(runner.shutil,'disk_usage',return_value=SimpleNamespace(free=4*1024**3-1)):
            code,processes,_=self.exercise({'status':'OBSERVED_UNQUALIFIED'},{'status':'PASS'})
        self.assertEqual(code,2)
        result=json.loads((self.args.out/'result.json').read_text())
        self.assertEqual(result['status'],'FAIL')
        self.assertIn('disk reserve',result['reason'])
        self.assertTrue((self.args.out/'stop.request').exists())
        self.assertGreater(processes[0].waits,0)


def load_tests(loader,tests,pattern):
    suite=unittest.TestSuite()
    for cls in (BoardRunnerTest,original.CollectorTests,original.SourceArchiveTests):
        suite.addTests(loader.loadTestsFromTestCase(cls))
    return suite


if __name__=='__main__':unittest.main()
