"""Exercise diagnostic control flow with Tcl mocks, not native timing analysis."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('report_rk_timing_coverage.tcl').resolve()
MOCK = r'''
proc set_param {args} {}
proc open_project {args} {}
proc get_runs {name} {return $name}
proc open_run {args} {}
proc current_design {} {return design}
proc get_clocks {args} {return [lindex $args end]}
proc get_property {name object} {
    global scenario
    if {$name eq "STATUS"} {
        if {$object eq "impl_1"} {return {Not started}}
        if {$scenario eq "incomplete"} {return {synth_design Running}}
        return {synth_design Complete!}
    }
    if {$name eq "PROGRESS"} {return 100%}
    if {$name eq "NEEDS_REFRESH"} {return [expr {$scenario eq "stale"}]}
    if {$name eq "PART"} {return xczu15eg-ffvb1156-2-i}
    if {$name eq "PERIOD"} {
        if {$object eq "clk_pl_0"} {return 10.0}
        return [expr {$scenario eq "wrong_clock" ? 20.0 : 25.0}]
    }
    if {$name eq "REF_NAME"} {return DSP_A_B_DATA}
    if {$name eq "DIRECTION"} {return IN}
    return 0
}
proc check_timing {args} {puts [linsert $args 0 CHECK_TIMING]}
proc report_exceptions {args} {puts [linsert $args 0 EXCEPTIONS]}
proc report_clocks {args} {}
proc get_cells {args} {
    global scenario
    if {$scenario eq "empty_dsp"} {return {}}
    return {core/ex_mul_p0/DSP_A_B_DATA_INST}
}
proc list_property {args} {return {REF_NAME BREG}}
proc get_pins {args} {return {}}
proc get_filesets {args} {return constrs_1}
proc get_files {args} {return {}}
proc close_project {} {puts CLOSE_PROJECT}
set scenario [lindex $argv 0]
set script [lindex $argv 1]
set argv [lrange $argv 2 end]
set argc [llength $argv]
if {[catch {source $script} message]} {puts stderr $message; exit 1}
'''


class TimingCoverageTests(unittest.TestCase):
    def run_case(self, scenario):
        scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
        self.assertEqual(scratch, Path('/home/yukidama/external/tmp').resolve(strict=True))
        with tempfile.TemporaryDirectory(prefix='ventium-timing-coverage-test.',dir=scratch) as folder:
            folder = Path(folder)
            project, driver, out = folder/'mock.xpr', folder/'driver.tcl', folder/'reports'
            project.touch(); driver.write_text(MOCK)
            proc = subprocess.run([shutil.which('tclsh'),str(driver),scenario,
                str(SCRIPT),str(project),str(out)],capture_output=True,text=True,timeout=5)
            report = (out/'integer_multiplier_dsp.rpt').read_text() if (out/'integer_multiplier_dsp.rpt').exists() else ''
            return proc,report

    def test_original_clocks_and_dsp_objects(self):
        proc,report = self.run_case('valid')
        self.assertEqual(proc.returncode,0,proc.stderr)
        self.assertIn('CHECK_TIMING -verbose',proc.stdout)
        self.assertIn('EXCEPTIONS -summary',proc.stdout)
        self.assertIn('EXCEPTIONS -coverage',proc.stdout)
        self.assertIn('CELL_COUNT 1',report)
        self.assertIn('PROPERTY BREG 0',report)
        self.assertIn('timing_closed=false hardware_accepted=false',proc.stdout)

    def test_rejects_stale_incomplete_or_wrong_clock(self):
        for scenario in ('stale','incomplete','wrong_clock'):
            with self.subTest(scenario=scenario):
                proc,report = self.run_case(scenario)
                self.assertEqual(proc.returncode,1)
                self.assertNotIn('CHECK_TIMING',proc.stdout)
                self.assertFalse(report)

    def test_rejects_empty_dsp_mapping(self):
        proc,report = self.run_case('empty_dsp')
        self.assertEqual(proc.returncode,1)
        self.assertIn('CELL_COUNT 0',report)
        self.assertNotIn('RK_TIMING_COVERAGE_COLLECTED',proc.stdout)


if __name__ == '__main__': unittest.main()
