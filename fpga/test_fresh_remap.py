"""Remap strategy contracts, not native Vivado or hardware acceptance."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

from audit_fresh_strategy import audit_synth, audit_impl
from run_fresh_strategy import implementation_policy
from test_audit_fresh_strategy import SCRIPT, PROPS

STRATEGY = 'routability-retime-remap-route-first'
HOOK = '/fixture/fpga/fresh_opt_remap_post.tcl'


def remap_log(threads=8):
    return (f'FRESH-NATIVE-THREADS-CHECK observed={threads}\n'
            'Command: opt_design -directive RuntimeOptimized\n'
            'opt_design completed successfully\n'
            f'FRESH-LOGIC-REMAP-BEGIN threads={threads} command=opt_design-resynth_remap\n'
            'Command: opt_design -resynth_remap\n'
            'opt_design completed successfully\n'
            'FRESH-LOGIC-REMAP-END\n'
            'Command: place_design -directive AltSpreadLogic_high\n'
            'Command: route_design -directive AlternateCLBRouting\n')


def impl_fixture(threads=8):
    script = (f'set_param general.maxThreads {threads}\n'
              'opt_design -directive RuntimeOptimized\n'
              f'source {HOOK}\n'
              'place_design -directive AltSpreadLogic_high\n'
              'route_design -directive AlternateCLBRouting\n')
    props = ''.join(f'STEPS.{step}.IS_ENABLED bool false 0\n'
                    f'STEPS.{step}.ARGS.DIRECTIVE enum false Default\n'
                    f'STEPS.{step}.ARGS.MORE OPTIONS string false\n'
                    for step in ('PHYS_OPT_DESIGN', 'POST_ROUTE_PHYS_OPT_DESIGN'))
    props += ('STEPS.OPT_DESIGN.ARGS.DIRECTIVE enum false RuntimeOptimized\n'
              'STEPS.OPT_DESIGN.ARGS.MORE OPTIONS string false\n'
              f'STEPS.OPT_DESIGN.TCL.POST file false {HOOK}\n')
    return script, props, remap_log(threads)


class RemapStrategyTests(unittest.TestCase):
    def test_named_strategy_retains_exact_synthesis_and_thread_policy(self):
        props = PROPS.replace('PerformanceOptimized', 'AlternateRoutability').replace('enum false auto', 'enum false on')
        for synth, apr in ((1, 4), (8, 8)):
            with self.subTest(synth=synth, apr=apr):
                script = SCRIPT.replace('maxThreads 1', f'maxThreads {synth}').replace('PerformanceOptimized', 'AlternateRoutability').rstrip()+' -global_retiming on\n'
                self.assertEqual(implementation_policy(STRATEGY, synth, 'unbounded'), apr)
                result = audit_synth(script, props, STRATEGY, synth)
                self.assertTrue(result['timing_driven'])
                self.assertFalse(result['prior_checkpoint_input'])
                for bad in (script.replace('retiming on', 'retiming off'), script+'read_checkpoint old.dcp\n'):
                    with self.assertRaises(ValueError): audit_synth(bad, props, STRATEGY, synth)
        with self.assertRaises(ValueError): implementation_policy(STRATEGY, 2, 'unbounded')

    def test_remap_requires_exact_native_execution_not_just_hook_markers(self):
        for threads in (4, 8):
            with self.subTest(threads=threads):
                script, props, log = impl_fixture(threads)
                result = audit_impl(script, props, STRATEGY, threads, log)
                self.assertEqual(result['logic_remap_operations'], ['-resynth_remap'])
                for bad in (None, '', log.replace('Command: opt_design -resynth_remap\n', ''),
                            log.replace('opt_design completed successfully\n', '', 1),
                            log.replace('opt_design completed successfully\n', ''),
                            log.replace('RuntimeOptimized', 'ExploreWithRemap'),
                            log.replace('-resynth_remap', '-aggressive_remap'),
                            log.replace('FRESH-LOGIC-REMAP-END\n', ''),
                            log+'Command: opt_design -resynth_remap\n',
                            log+'ERROR: remapping failed\n',
                            log.replace('FRESH-LOGIC-REMAP-END\n', 'FRESH-LOGIC-REMAP-END\n'*2),
                            log.replace(f'BEGIN threads={threads}', 'BEGIN threads=2')):
                    with self.subTest(bad_log=bad), self.assertRaises(ValueError):
                        audit_impl(script, props, STRATEGY, threads, bad)
                misplaced = log.replace('FRESH-LOGIC-REMAP-END\n', '')+'FRESH-LOGIC-REMAP-END\n'
                with self.assertRaises(ValueError): audit_impl(script, props, STRATEGY, threads, misplaced)

    def test_source_and_property_must_identify_the_same_single_post_hook(self):
        script, props, log = impl_fixture()
        for bad in (script.replace(f'source {HOOK}\n', ''),
                    script+f'source {HOOK}\n',
                    script.replace(f'source {HOOK}', 'source /other/fresh_opt_remap_post.tcl'),
                    script.replace(f'source {HOOK}\n', '')+f'source {HOOK}\n',
                    script+'opt_design -resynth_remap\n',
                    script+'phys_opt_design -retime\n',
                    script.replace('AltSpreadLogic_high', 'ExtraTimingOpt')):
            with self.subTest(bad_script=bad), self.assertRaises(ValueError):
                audit_impl(bad, props, STRATEGY, 8, log)
        for bad in (props.replace(HOOK, '/other/not_the_hook.tcl'),
                    props.replace('enum false RuntimeOptimized', 'enum false ExploreWithRemap'),
                    props.replace('OPTIONS string false\n', 'OPTIONS string false -bram_power_opt\n'),
                    props.replace('IS_ENABLED bool false 0', 'IS_ENABLED bool false 1')):
            with self.subTest(bad_props=bad), self.assertRaises(ValueError):
                audit_impl(script, bad, STRATEGY, 8, log)

    def test_old_strategy_cannot_silently_run_remap_hook(self):
        script, props, log = impl_fixture()
        with self.assertRaises(ValueError):
            audit_impl(script, props, 'routability-retime-route-first', 8, log)

    def test_launcher_pins_new_dependency(self):
        source = Path(__file__).with_name('run_fresh_strategy.py').read_text()
        self.assertIn("'fresh_opt_remap_post.tcl'", source)

    def test_probe_configures_same_two_pass_strategy_before_any_native_launch(self):
        directory = Path(__file__).parent.resolve()
        script = (directory/'test_native_route_first.tcl').read_text()
        prefix = script.split('foreach {run threads}')[0]
        # The copied prefix otherwise resolves helpers relative to the test
        # script. Replace only the helper-directory expression, not settings.
        prefix = prefix.replace('[file dirname [info script]]', '{'+str(directory)+'}')
        prefix = prefix.replace('[file dirname [file normalize [info script]]]', '{'+str(directory)+'}')
        mocks = '''
proc version {args} {return 2025.2}
proc create_project {args} {}
proc launch_runs {args} {error "native launch forbidden in host test"}
proc current_project {} {return project}
proc current_fileset {} {return sources}
proc config_ip_cache {args} {set ::props(project,IP_CACHE_PERMISSIONS) disable}
proc add_files {args} {}
proc get_runs {r} {return $r}
proc report_property {args} {}
proc set_property {args} {
 if {[lindex $args 0] eq "-name"} {
  lassign $args a prop b value c obj
 } else {lassign $args prop value obj}
 set ::props($obj,$prop) $value
}
proc get_property {p o} {return $::props($o,$p)}
'''
        for strategy in ('performance-route-first', 'routability-route-first',
                         'routability-retime-route-first', STRATEGY):
            for profile, threads in (('serial_apr4', 4), ('parallel8', 8)):
                with self.subTest(strategy=strategy, profile=profile), tempfile.TemporaryDirectory(prefix='remap-probe-config-') as td:
                    expected_hook = str(directory/'fresh_opt_remap_post.tcl') if strategy == STRATEGY else ''
                    check = (f'\nif {{[get_property STEPS.OPT_DESIGN.TCL.POST impl_1] ne {{{expected_hook}}}}} {{error "probe remap hook drift"}}\n'
                             'if {[get_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE impl_1] ne "RuntimeOptimized"} {error "normal pass drift"}\n'
                             'if {[get_property {STEPS.OPT_DESIGN.ARGS.MORE OPTIONS} impl_1] ne ""} {error "extra opt switches"}\n'
                             f'if {{$apr_threads != {threads}}} {{error "thread drift"}}\n')
                    runner = Path(td)/'test.tcl'
                    runner.write_text(mocks+f'set argc 3\nset argv [list {{{td}/output}} {strategy} {profile}]\n'+prefix+check)
                    result = subprocess.run(['tclsh', str(runner)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout+result.stderr)

    def test_probe_python_auditor_body_rejects_missing_native_pass(self):
        directory = Path(__file__).parent.resolve()
        probe = (directory/'test_native_route_first.tcl').read_text()
        self.assertIn('exec /usr/bin/python3 -I -B -c $audit_python', probe)
        body = probe.split('set audit_python {\n', 1)[1].split('\n}\n', 1)[0]
        script, props, log = impl_fixture()
        with tempfile.TemporaryDirectory(prefix='remap-probe-audit-') as td:
            root = Path(td)/'path with spaces'
            root.mkdir()
            native = root/'route_first_probe.tcl'; native.write_text(script)
            properties = root/'impl-properties.rpt'; properties.write_text(props)
            for evidence, valid in ((log, True), (log.replace('Command: opt_design -resynth_remap\n', ''), False)):
                with self.subTest(valid=valid):
                    (root/'runme.log').write_text(evidence)
                    # Model the incompatible Python environment exported by
                    # native Vivado; -I must ignore it before importing codecs.
                    environment = dict(os.environ, PYTHONHOME=str(root/'vendor-python'),
                                       PYTHONPATH=str(root/'vendor-site-packages'))
                    result = subprocess.run(['/usr/bin/python3', '-I', '-B', '-c', body, str(directory),
                                             str(native), str(properties), STRATEGY, '8'],
                                            capture_output=True, text=True, timeout=10, env=environment)
                    self.assertEqual(result.returncode == 0, valid, result.stdout+result.stderr)
                    if valid:
                        self.assertIn('"logic_remap_operations": ["-resynth_remap"]', result.stdout)
                    else:
                        self.assertIn('remap execution evidence', result.stderr)


if __name__ == '__main__': unittest.main()
