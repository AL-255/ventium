import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from run_programmable_incremental import validate_reports, WHOLE_RUN_LIMIT_SECONDS


class ProductGate(unittest.TestCase):
    def setUp(self):
        self.args = dict(route='\n'.join('# of '+n+'.... : '+str(v)+' :' for n,v in (
            ('routable nets',223999),('fully routed nets',223999),('nets with routing errors',0))),
            drc='Design State : Fully Routed\n| Warning | ordinary |',
            clocks='mmcm_clk 25.000 {0.000 12.500}\nclk_pl_0 10.000 {0.000 5.000}\n',
            route_time=dict(route_elapsed_ms=100000,limit_ms=14400000),
            initial=dict(stage='initial',primitive_cells=280000,matched_pct=99.9,reused_pct=99.8),
            placed=dict(stage='placed',primitive_cells=280000,matched_pct=99.9,reused_pct=99.7))

    def test_complete(self):
        self.assertEqual(validate_reports(**self.args)['fully routed nets'],223999)

    def test_partial_route(self):
        self.args['route'] = self.args['route'].replace('fully routed nets.... : 223999','fully routed nets.... : 223998')
        with self.assertRaises(ValueError): validate_reports(**self.args)

    def test_route_error(self):
        self.args['route'] = self.args['route'].replace('errors.... : 0','errors.... : 1')
        with self.assertRaises(ValueError): validate_reports(**self.args)

    def test_drc(self):
        for severity in ('Error','Critical Warning'):
            with self.subTest(severity=severity), self.assertRaises(ValueError):
                validate_reports(**(self.args | {'drc':'Design State : Fully Routed\n| '+severity+' | failure |'}))

    def test_wrong_clock(self):
        self.args['clocks'] = self.args['clocks'].replace('25.000','20.000')
        with self.assertRaises(ValueError): validate_reports(**self.args)

    def test_strict_time_limit(self):
        self.args['route_time']['route_elapsed_ms'] = 14400000
        with self.assertRaises(ValueError): validate_reports(**self.args)

    def test_insufficient_reuse(self):
        for stage,key,value in (('initial','matched_pct',94.99),('placed','reused_pct',89.99)):
            args = copy.deepcopy(self.args)
            args[stage][key] = value
            with self.subTest(stage=stage), self.assertRaises(ValueError): validate_reports(**args)

    def test_duplicate_route_count(self):
        self.args['route'] += '\n# of routable nets.... : 223999 :'
        with self.assertRaises(ValueError): validate_reports(**self.args)

    def test_outer_limit_leaves_shutdown_margin(self):
        self.assertLess(WHOLE_RUN_LIMIT_SECONDS+60+10,14400)

    def test_tcl_reuse_json(self):
        script = Path(__file__).with_name('launch_programmable_incremental.tcl').resolve()
        with tempfile.TemporaryDirectory(prefix='ventium-reuse-json-test.',dir=os.environ['TMPDIR']) as folder:
            code = '''
proc version args {return 2025.2}
proc set_param args {}
proc open_checkpoint args {error BEFORE_NATIVE}
set argc 3
set argv [list unused unused {%s}]
set rc [catch {source {%s}} why]
if {$rc != 1 || $why ne "BEFORE_NATIVE"} {puts stderr $why; exit 1}
proc get_cells args {return [lrepeat 200001 primitive]}
if {[catch {reuse_counts initial} why]} {puts stderr $why; exit 1}
''' % (folder,script)
            subprocess.run(['tclsh'],input=code,text=True,check=True,capture_output=True,timeout=10)
            row = json.loads((Path(folder)/'initial-reuse.json').read_text())
            self.assertEqual(row,dict(stage='initial',primitive_cells=200001,matched_pct=100,reused_pct=100))


if __name__ == '__main__': unittest.main()
