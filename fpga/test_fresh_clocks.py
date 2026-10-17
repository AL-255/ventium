"""Exercise actual reporting-hook clock selection with MMCM feedback present."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class ClockTests(unittest.TestCase):
    def test_axi_is_identified_not_counted_by_frequency(self):
        for name in ('fresh_synth_post.tcl', 'fresh_reports.tcl'):
            text = Path(__file__).with_name(name).read_text()
            # The final-report hook performs unrelated native route/timing
            # reporting after role selection. Exercise the selection verbatim.
            if name == 'fresh_reports.tcl':
                text = text.split('foreach {from to}')[0]+'\nclose $f\n'
            for case, expected in (('valid', 0), ('no_axi', 1), ('slow_axi', 1),
                                   ('no_core', 1), ('duplicate_core', 1)):
                with tempfile.TemporaryDirectory(prefix='fresh-clock-test-') as td:
                    setup = '''
proc get_clocks {} {
 if {$::case eq "no_axi"} {return {mmcm_clk mmcm_fb}}
 if {$::case eq "no_core"} {return {clk_pl_0 mmcm_fb}}
 if {$::case eq "duplicate_core"} {return {clk_pl_0 mmcm_clk mmcm_fb extra_core}}
 return {clk_pl_0 mmcm_clk mmcm_fb}
}
proc get_property {p c} {
 if {$p eq "NAME"} {return $c}
 if {$p ne "PERIOD"} {error "unexpected property"}
 if {$c in {mmcm_clk extra_core}} {return 25.0}
 if {$c eq "clk_pl_0" && $::case eq "slow_axi"} {return 12.0}
 return 10.0
}
proc report_timing_summary {args} {}
proc report_utilization {args} {}
'''
                    script = Path(td)/'test.tcl'
                    script.write_text(setup+f'\nset ::case {case}\nset out {{{td}}}\nset ::env(VEN_FRESH_OUT) $out\n'+text)
                    result = subprocess.run(['tclsh', str(script)], capture_output=True, text=True)
                    with self.subTest(hook=name, case=case):
                        self.assertEqual(result.returncode, expected, result.stdout+result.stderr)


if __name__ == '__main__': unittest.main()
