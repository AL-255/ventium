"""Performance mapping with congestion-oriented APR: tooling, not QoR proof."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from audit_fresh_strategy import audit_synth, audit_impl
from run_fresh_strategy import STRATEGIES, argument_parser, implementation_policy
from test_audit_fresh_strategy import SCRIPT, PROPS

STRATEGY = 'performance-retime-routability-route-first'


class PerformanceRoutabilityTests(unittest.TestCase):
    def test_launcher_accepts_named_strategy_without_native_launch(self):
        self.assertIn(STRATEGY, STRATEGIES)
        args = argument_parser().parse_args(['--strategy', STRATEGY, '--output', 'unused'])
        self.assertEqual(args.threads, 8)
        self.assertEqual(args.memory_profile, 'unbounded')
        self.assertEqual(implementation_policy(STRATEGY, 8, 'unbounded'), 8)
        self.assertEqual(implementation_policy(STRATEGY, 1, 'unbounded'), 4)
        with self.assertRaises(ValueError):
            implementation_policy(STRATEGY, 2, 'unbounded')

    def test_native_synthesis_requires_performance_mapping_and_retiming(self):
        props = PROPS.replace('enum false auto', 'enum false on')
        for threads in (1, 8):
            script = SCRIPT.replace('maxThreads 1', f'maxThreads {threads}').rstrip()+' -global_retiming on\n'
            result = audit_synth(script, props, STRATEGY, threads)
            self.assertFalse(result['prior_checkpoint_input'])
            for bad in (script.replace('PerformanceOptimized', 'AlternateRoutability'),
                        script.replace('retiming on', 'retiming off'),
                        script.replace('retiming on', 'retiming auto'),
                        script.replace(' -global_retiming on', ''),
                        script+'read_checkpoint old.dcp\n',
                        script+'open_checkpoint old.dcp\n'):
                with self.subTest(threads=threads, bad=bad), self.assertRaises(ValueError):
                    audit_synth(bad, props, STRATEGY, threads)
            for bad in (props.replace('PerformanceOptimized', 'AlternateRoutability'),
                        props.replace('enum false on', 'enum false off')):
                with self.assertRaises(ValueError): audit_synth(script, bad, STRATEGY, threads)

    def test_implementation_requires_existing_congestion_options_without_remap(self):
        props = ''.join(f'STEPS.{step}.IS_ENABLED bool false 0\n'
                        f'STEPS.{step}.ARGS.DIRECTIVE enum false Default\n'
                        f'STEPS.{step}.ARGS.MORE OPTIONS string false\n'
                        for step in ('PHYS_OPT_DESIGN', 'POST_ROUTE_PHYS_OPT_DESIGN'))
        for threads in (4, 8):
            script = (f'set_param general.maxThreads {threads}\n'
                      'opt_design -directive RuntimeOptimized\n'
                      'place_design -directive AltSpreadLogic_high\n'
                      'route_design -directive AlternateCLBRouting\n')
            result = audit_impl(script, props, STRATEGY, threads)
            self.assertEqual(result['physical_operations'], [])
            self.assertEqual(result['logic_remap_operations'], [])
            for bad in (script.replace('AltSpreadLogic_high', 'AltSpreadLogic_medium'),
                        script.replace('AltSpreadLogic_high', 'ExtraTimingOpt'),
                        script.replace('AlternateCLBRouting', 'NoTimingRelaxation'),
                        script+'phys_opt_design -retime\n',
                        script+'source /fixture/fresh_opt_remap_post.tcl\n'):
                with self.subTest(threads=threads, bad=bad), self.assertRaises(ValueError):
                    audit_impl(bad, props, STRATEGY, threads)
            with self.assertRaises(ValueError):
                audit_impl(script, props.replace('IS_ENABLED bool false 0', 'IS_ENABLED bool false 1'),
                           STRATEGY, threads)
            with self.assertRaises(ValueError):
                audit_impl(script, props, STRATEGY, threads,
                           'Command: opt_design -resynth_remap\n')

    def test_probe_uses_same_exact_directives_as_full_flow(self):
        source = Path(__file__).with_name('test_native_route_first.tcl').read_text()
        prefix = source.split('set out [file normalize')[0]
        for profile, synth, apr in (('serial_apr4', 1, 4), ('parallel8', 8, 8)):
            with self.subTest(profile=profile), tempfile.TemporaryDirectory(prefix='performance-route-probe-') as td:
                code = f'set argc 3\nset argv [list unused {STRATEGY} {profile}]\n'+prefix
                for var, expected in (('synth_directive', 'PerformanceOptimized'),
                                      ('synth_retiming', 'on'),
                                      ('place_directive', 'AltSpreadLogic_high'),
                                      ('route_directive', 'AlternateCLBRouting'),
                                      ('synth_threads', str(synth)), ('apr_threads', str(apr))):
                    code += f'\nif {{${var} ne "{expected}"}} {{error "probe drift: {var}"}}\n'
                script = Path(td)/'test.tcl'; script.write_text(code)
                result = subprocess.run(['tclsh', str(script)], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)


if __name__ == '__main__': unittest.main()
