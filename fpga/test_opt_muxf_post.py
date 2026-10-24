"""Host contract tests only: these do not run Vivado or establish QoR."""
from pathlib import Path
import subprocess
import tempfile
import unittest


HOOK = Path(__file__).with_name('fresh_opt_muxf_post.tcl')


class MuxfHookTests(unittest.TestCase):
    def run_hook(self, *, version='2025.2', part='xczu15eg-ffvb1156-2-i',
                 threads='8', failure=False, twice=False, clocks='core axi',
                 paths='one_path', report_failure='', stale=False, empty_muxes=False):
        code = f'''
proc version {{args}} {{return {{{version}}}}}
proc current_design {{}} {{return test_design}}
proc get_property {{name object}} {{
    if {{$name eq "PERIOD"}} {{
        if {{$object eq "axi"}} {{return 10.0}}
        return 25.0
    }}
    if {{$name ne "PART" || $object ne "test_design"}} {{error "unexpected query"}}
    return {{{part}}}
}}
proc get_param {{name}} {{
    if {{$name ne "general.maxThreads"}} {{error "unexpected parameter"}}
    return {{{threads}}}
}}
proc set_param {{args}} {{error "must not silently change native thread setting"}}
proc read_checkpoint {{args}} {{error "no checkpoint reads allowed"}}
proc open_checkpoint {{args}} {{error "no checkpoint reads allowed"}}
proc set_false_path {{args}} {{error "no timing waivers allowed"}}
proc set_multicycle_path {{args}} {{error "no timing waivers allowed"}}
proc get_clocks {{}} {{return {{{clocks}}}}}
proc get_timing_paths {{args}} {{
    if {{$args ne "-setup -from core -to core -max_paths 1"}} {{error "wrong clock path query"}}
    return {{{paths}}}
}}
proc report_timing {{args}} {{
    set stage [expr {{[info exists ::test_optimized] ? "after" : "before"}}]
    set expected [list -from core -to core -max_paths 20 -path_type full_clock_expanded \
        -file "fresh-muxf-$stage-core-paths.rpt"]
    if {{$args ne $expected}} {{error "wrong timing report"}}
    if {{$stage eq {{{report_failure}}}}} {{error "native-report-failure"}}
    puts "TEST-TIMING $stage"
}}
proc report_utilization {{args}} {{
    set stage [expr {{[info exists ::test_optimized] ? "after" : "before"}}]
    if {{$args ne [list -hierarchical -file "fresh-muxf-$stage-utilization.rpt"]}} {{
        error "wrong utilization report"
    }}
    puts "TEST-UTILIZATION $stage"
}}
proc get_cells {{args}} {{
    set primitive [lindex [lindex $args end] end]
    if {{$args ne [list -quiet -hierarchical -filter "REF_NAME == $primitive"] ||
        $primitive ni {{MUXF7 MUXF8 MUXF9}}}} {{error "unexpected MUX query"}}
    if {{{int(empty_muxes)}}} {{return {{}}}}
    if {{[info exists ::test_optimized]}} {{
        set counts [dict create MUXF7 2 MUXF8 1 MUXF9 1]
    }} else {{
        set counts [dict create MUXF7 4 MUXF8 2 MUXF9 1]
    }}
    return [lrepeat [dict get $counts $primitive] $primitive]
}}
proc set_property {{args}} {{error "no preservation or timing property changes allowed"}}
proc create_clock {{args}} {{error "no clock changes allowed"}}
proc set_clock_groups {{args}} {{error "no timing waivers allowed"}}
proc opt_design {{args}} {{
    if {{$args ne "-muxf_remap"}} {{error "unexpected optimization options"}}
    puts "TEST-OPT-CALL $args"
    {'error "native-remap-failure"' if failure else ''}
    set ::test_optimized 1
}}
source {{{HOOK}}}
{'source {' + str(HOOK) + '}' if twice else ''}
'''
        with tempfile.TemporaryDirectory(prefix='muxf-hook-test-') as directory:
            script = Path(directory)/'test.tcl'
            script.write_text(code)
            if stale:
                (Path(directory)/'fresh-muxf-after-core-paths.rpt').write_text('old report')
            return subprocess.run(['tclsh', str(script)], text=True,
                                  capture_output=True, timeout=10, cwd=directory)

    def test_exact_explicit_pass_for_supported_native_threads(self):
        for threads in ('4', '8'):
            with self.subTest(threads=threads):
                result = self.run_hook(threads=threads)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [
                    'TEST-TIMING before', 'TEST-UTILIZATION before',
                    'FRESH-MUXF-COUNTS stage=before primitive=MUXF7 count=4',
                    'FRESH-MUXF-COUNTS stage=before primitive=MUXF8 count=2',
                    'FRESH-MUXF-COUNTS stage=before primitive=MUXF9 count=1',
                    f'FRESH-MUXF-REMAP-BEGIN threads={threads} command=opt_design-muxf_remap',
                    'TEST-OPT-CALL -muxf_remap',
                    'TEST-TIMING after', 'TEST-UTILIZATION after',
                    'FRESH-MUXF-COUNTS stage=after primitive=MUXF7 count=2',
                    'FRESH-MUXF-COUNTS stage=after primitive=MUXF8 count=1',
                    'FRESH-MUXF-COUNTS stage=after primitive=MUXF9 count=1',
                    'FRESH-MUXF-REMAP-END'])

    def test_zero_mux_count_is_reported_not_mislabeled_as_an_improvement(self):
        result = self.run_hook(empty_muxes=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        counts = [line for line in result.stdout.splitlines() if line.startswith('FRESH-MUXF-COUNTS ')]
        self.assertEqual(len(counts), 6)
        self.assertTrue(all(line.endswith('count=0') for line in counts))

    def test_missing_or_ambiguous_clock_or_path_refuses_optimization(self):
        for arguments in (dict(clocks='axi'), dict(clocks='core second_core'), dict(paths='')):
            with self.subTest(arguments=arguments):
                result = self.run_hook(**arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('TEST-OPT-CALL', result.stdout)

    def test_report_failure_cannot_claim_success(self):
        for stage in ('before', 'after'):
            with self.subTest(stage=stage):
                result = self.run_hook(report_failure=stage)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('native-report-failure', result.stderr)
                self.assertNotIn('FRESH-MUXF-REMAP-END', result.stdout)
                self.assertEqual('TEST-OPT-CALL' in result.stdout, stage == 'after')

    def test_preexisting_evidence_refuses_optimization(self):
        result = self.run_hook(stale=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('pre-existing remap evidence', result.stderr)
        self.assertNotIn('TEST-OPT-CALL', result.stdout)

    def test_reject_wrong_environment_before_optimization(self):
        cases = [dict(version='2025.1'), dict(part='xczu15eg-ffvb1156-1-i')]
        cases += [dict(threads=value) for value in ('1', '2', '8.0', '16', '')]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = self.run_hook(**arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('TEST-OPT-CALL', result.stdout)
                self.assertNotIn('FRESH-MUXF-REMAP-END', result.stdout)

    def test_native_failure_propagates_without_success_marker(self):
        result = self.run_hook(failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('native-remap-failure', result.stderr)
        self.assertEqual(result.stdout.count('TEST-OPT-CALL'), 1)
        self.assertNotIn('FRESH-MUXF-REMAP-END', result.stdout)

    def test_repeated_source_cannot_run_a_second_pass(self):
        result = self.run_hook(twice=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('duplicate remap pass', result.stderr)
        self.assertEqual(result.stdout.count('TEST-OPT-CALL'), 1)
        self.assertEqual(result.stdout.count('FRESH-MUXF-REMAP-END'), 1)


if __name__ == '__main__':
    unittest.main()
