"""One-delta timing routing: retain MUXF/synthesis/placement and fail closed."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from audit_fresh_strategy import audit_synth, audit_impl
from run_fresh_strategy import implementation_policy
from test_audit_fresh_strategy import SCRIPT, PROPS
from test_fresh_muxf import STRATEGY, EXPLORE_STRATEGY, HOOK, impl_fixture


def fixture(threads=8):
    return tuple(s.replace('AlternateCLBRouting', 'Explore')
                 for s in impl_fixture(threads))


class MuxfExploreTests(unittest.TestCase):
    def test_exact_synthesis_and_threads_retained(self):
        props = PROPS.replace('enum false auto', 'enum false on')
        for synth, apr in ((1, 4), (8, 8)):
            script = SCRIPT.replace('maxThreads 1', f'maxThreads {synth}').rstrip()+' -global_retiming on\n'
            self.assertEqual(implementation_policy(EXPLORE_STRATEGY, synth, 'unbounded'), apr)
            self.assertEqual(audit_synth(script, props, EXPLORE_STRATEGY, synth),
                             audit_synth(script, props, STRATEGY, synth))
            for bad in (script.replace('retiming on', 'retiming off'),
                        script.replace('PerformanceOptimized', 'AlternateRoutability'),
                        script+'read_checkpoint old.dcp\n'):
                with self.assertRaises(ValueError):
                    audit_synth(bad, props, EXPLORE_STRATEGY, synth)
        with self.assertRaises(ValueError): implementation_policy(EXPLORE_STRATEGY, 2, 'unbounded')

    def test_old_and_new_routing_are_not_interchangeable(self):
        for threads in (4, 8):
            old_script, props, old_log = impl_fixture(threads)
            script, _, log = fixture(threads)
            result = audit_impl(script, props, EXPLORE_STRATEGY, threads, log)
            self.assertEqual(result['logic_remap_operations'], ['-muxf_remap'])
            self.assertEqual(result['physical_operations'], [])
            self.assertEqual([c['count'] for c in result['muxf_counts']], [4, 2, 1, 0, 0, 0])
            self.assertFalse(result['completion_verified'])
            for strategy, native, evidence in (
                    (EXPLORE_STRATEGY, old_script, old_log),
                    (EXPLORE_STRATEGY, script, old_log),
                    (EXPLORE_STRATEGY, old_script, log),
                    (STRATEGY, script, log), (STRATEGY, old_script, log)):
                with self.subTest(strategy=strategy), self.assertRaises(ValueError):
                    audit_impl(native, props, strategy, threads, evidence)

    def test_new_mode_keeps_hook_count_order_and_completion_guards(self):
        script, props, log = fixture()
        first = 'FRESH-MUXF-COUNTS stage=before primitive=MUXF7 count=4\n'
        for bad in (None, '', log.replace(first, ''), log+first,
                    log.replace('count=4', 'count=-1'),
                    log.replace('stage=after', 'stage=before'),
                    log.replace('Command: opt_design -muxf_remap\n', ''),
                    log.replace('opt_design completed successfully\n', '', 1),
                    log.replace('FRESH-MUXF-REMAP-END\n', '')+'FRESH-MUXF-REMAP-END\n',
                    log+'Command: phys_opt_design -retime\n',
                    log.replace('BEGIN threads=8', 'BEGIN threads=4'),
                    log+'ERROR: native failure\n'):
            with self.subTest(log=bad), self.assertRaises(ValueError):
                audit_impl(script, props, EXPLORE_STRATEGY, 8, bad)
        for bad in (script.replace(f'source {HOOK}\n', ''),
                    script+f'source {HOOK}\n',
                    script+'source /fixture/fresh_opt_remap_post.tcl\n',
                    script+'phys_opt_design\n',
                    script.replace('AltSpreadLogic_high', 'ExtraTimingOpt'),
                    script.replace('Explore', 'NoTimingRelaxation')):
            with self.subTest(script=bad), self.assertRaises(ValueError):
                audit_impl(bad, props, EXPLORE_STRATEGY, 8, log)
        for bad in (props.replace(HOOK, '/other/hook.tcl'),
                    props.replace('IS_ENABLED bool false 0', 'IS_ENABLED bool false 1'),
                    props.replace('OPTIONS string false\n', 'OPTIONS string false -remap\n')):
            with self.assertRaises(ValueError): audit_impl(script, bad, EXPLORE_STRATEGY, 8, log)

    def test_native_probe_auditor_checks_routing_mode_and_population(self):
        directory = Path(__file__).parent.resolve()
        probe = (directory/'test_native_route_first.tcl').read_text()
        body = probe.split('set audit_python {\n', 1)[1].split('\n}\n', 1)[0]
        script, props, log = fixture()
        empty = log.replace('count=4', 'count=0').replace('count=2', 'count=0').replace('count=1', 'count=0')
        unchanged = log
        for primitive, count in (('MUXF7', 4), ('MUXF8', 2), ('MUXF9', 1)):
            unchanged = unchanged.replace(f'stage=after primitive={primitive} count=0',
                                          f'stage=after primitive={primitive} count={count}')
        with tempfile.TemporaryDirectory(prefix='muxf-explore-probe-audit-') as td:
            root = Path(td)
            native = root/'route_first_probe.tcl'; native.write_text(script)
            properties = root/'impl-properties.rpt'; properties.write_text(props)
            for evidence, valid in ((log, True), (empty, False), (unchanged, False),
                                    (log.replace('Explore', 'AlternateCLBRouting'), False)):
                (root/'runme.log').write_text(evidence)
                result = subprocess.run(['/usr/bin/python3', '-I', '-B', '-c', body,
                                         str(directory), str(native), str(properties), EXPLORE_STRATEGY, '8'],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, valid, result.stdout+result.stderr)


if __name__ == '__main__': unittest.main()
