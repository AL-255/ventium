"""Ordered post-MUXF LUT remapping contracts; these are not CPU/QoR gates."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from audit_fresh_strategy import audit_impl, audit_synth, MUXF_AGGRESSIVE_STRATEGY as STRATEGY
from run_fresh_strategy import implementation_policy
from test_audit_fresh_strategy import SCRIPT, PROPS
from test_fresh_muxf import impl_fixture, HOOK as OLD_HOOK, STRATEGY as CONTROL
import test_opt_muxf_post

HOOK = '/fixture/fpga/fresh_opt_muxf_aggressive_post.tcl'


def aggressive_log(threads=8):
    return fixture(threads)[2]


def fixture(threads=8):
    script, props, log = impl_fixture(threads)
    extra = (f'FRESH-MUXF-AGGRESSIVE-BEGIN threads={threads} command=opt_design-aggressive_remap\n'
             'Command: opt_design -aggressive_remap\n'
             'opt_design completed successfully\n' + ''.join(
                 f'FRESH-MUXF-COUNTS stage=post_aggressive primitive={p} count=0\n'
                 for p in ('MUXF7', 'MUXF8', 'MUXF9')) + 'FRESH-MUXF-AGGRESSIVE-END\n')
    return (script.replace(OLD_HOOK, HOOK), props.replace(OLD_HOOK, HOOK),
            log.replace('FRESH-MUXF-REMAP-END\n', 'FRESH-MUXF-REMAP-END\n'+extra))


class AggressiveMuxfTests(unittest.TestCase):
    def test_synthesis_is_unchanged(self):
        props = PROPS.replace('enum false auto', 'enum false on')
        for synth, apr in ((1, 4), (8, 8)):
            native = SCRIPT.replace('maxThreads 1', f'maxThreads {synth}').rstrip()+' -global_retiming on\n'
            self.assertEqual(implementation_policy(STRATEGY, synth, 'unbounded'), apr)
            self.assertEqual(audit_synth(native, props, STRATEGY, synth),
                             audit_synth(native, props, CONTROL, synth))
        with self.assertRaises(ValueError): implementation_policy(STRATEGY, 2, 'unbounded')

    def test_exact_three_pass_order_and_nine_counts(self):
        for threads in (4, 8):
            script, props, log = fixture(threads)
            result = audit_impl(script, props, STRATEGY, threads, log)
            self.assertEqual(result['logic_remap_operations'], ['-muxf_remap', '-aggressive_remap'])
            self.assertEqual(result['physical_operations'], [])
            self.assertEqual(len(result['muxf_counts']), 9)
            self.assertFalse(result['completion_verified'])
            with self.assertRaises(ValueError): audit_impl(script, props, CONTROL, threads, log)
            with self.assertRaises(ValueError): audit_impl(*impl_fixture(threads)[:2], STRATEGY, threads, impl_fixture(threads)[2])

    def test_reject_missing_extra_reordered_failed_or_unrequested_operations(self):
        script, props, log = fixture()
        line = 'FRESH-MUXF-COUNTS stage=post_aggressive primitive=MUXF7 count=0\n'
        for bad in (log.replace('Command: opt_design -aggressive_remap\n', ''),
                    log.replace('Command: opt_design -aggressive_remap', 'Command: opt_design -resynth_remap'),
                    log.replace('opt_design completed successfully\n', '', 1),
                    log.replace('FRESH-MUXF-AGGRESSIVE-END\n', ''),
                    log.replace(line, ''), log+line, log.replace(line, line.replace('count=0', 'count=-1')),
                    log.replace('stage=post_aggressive', 'stage=before'),
                    log.replace('FRESH-MUXF-AGGRESSIVE-END\n', '')+'FRESH-MUXF-AGGRESSIVE-END\n',
                    log+'Command: opt_design -bram_power_opt\n', log+'ERROR: native failure\n',
                    log.replace('AGGRESSIVE-BEGIN threads=8', 'AGGRESSIVE-BEGIN threads=4')):
            with self.subTest(log=bad), self.assertRaises(ValueError):
                audit_impl(script, props, STRATEGY, 8, bad)
        for bad in (script.replace(HOOK, OLD_HOOK), script+f'source {OLD_HOOK}\n',
                    script+f'source {HOOK}\n', script.replace('AlternateCLBRouting', 'Explore')):
            with self.assertRaises(ValueError): audit_impl(bad, props, STRATEGY, 8, log)

    def run_hook(self, **kw):
        return test_opt_muxf_post.MuxfHookTests().run_hook(
            hook=Path(__file__).with_name('fresh_opt_muxf_aggressive_post.tcl'), aggressive=True, **kw)

    def test_native_hook_runs_both_explicit_operations_and_all_reports(self):
        for threads in ('4', '8'):
            result = self.run_hook(threads=threads)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual([s for s in lines if s.startswith('TEST-OPT-CALL')],
                             ['TEST-OPT-CALL -muxf_remap', 'TEST-OPT-CALL -aggressive_remap'])
            self.assertEqual([s for s in lines if s.startswith('TEST-TIMING')],
                             ['TEST-TIMING before', 'TEST-TIMING after', 'TEST-TIMING post_aggressive'])
            self.assertEqual(lines[-1], 'FRESH-MUXF-AGGRESSIVE-END')

    def test_hook_guards_before_either_operation(self):
        for args in (dict(stale='before'), dict(stale='after'), dict(stale='post_aggressive'),
                     dict(version='2025.1'), dict(part='other'), dict(threads='2')):
            result = self.run_hook(**args)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('TEST-OPT-CALL', result.stdout)

    def test_hook_does_not_swallow_native_or_report_failures(self):
        for args in (dict(failure=True), dict(aggressive_failure=True),
                     dict(report_failure='before'), dict(report_failure='after'),
                     dict(report_failure='post_aggressive')):
            result = self.run_hook(**args)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('FRESH-MUXF-AGGRESSIVE-END', result.stdout)
        result = self.run_hook(twice=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.count('TEST-OPT-CALL'), 2)

    def test_native_probe_auditor_requires_the_new_operation_and_reports(self):
        directory = Path(__file__).parent.resolve()
        probe = (directory/'test_native_route_first.tcl').read_text()
        body = probe.split('set audit_python {\n', 1)[1].split('\n}\n', 1)[0]
        script, props, log = fixture()
        empty = log.replace('count=4', 'count=0').replace('count=2', 'count=0').replace('count=1', 'count=0')
        with tempfile.TemporaryDirectory(prefix='muxf-aggressive-probe-audit-') as td:
            root = Path(td)
            native = root/'route_first_probe.tcl'; native.write_text(script)
            properties = root/'impl-properties.rpt'; properties.write_text(props)
            for evidence, valid in ((log, True), (empty, False),
                    (log.replace('Command: opt_design -aggressive_remap\n', ''), False),
                    (log.replace('post_aggressive', 'after'), False)):
                (root/'runme.log').write_text(evidence)
                result = subprocess.run(['/usr/bin/python3', '-I', '-B', '-c', body,
                    str(directory), str(native), str(properties), STRATEGY, '8'],
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, valid, result.stdout+result.stderr)


if __name__ == '__main__': unittest.main()
