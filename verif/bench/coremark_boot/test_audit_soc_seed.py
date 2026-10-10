"""Synthetic auditor controls; these never count as benchmark measurements."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import audit_soc_seed as a
from check_result import check
from test_check_result import CRCS, fixture


class SeedAudit(unittest.TestCase):
    def setUp(self):
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertTrue(Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch))
        self.tmp = tempfile.TemporaryDirectory(prefix='ventium-cm-audit-test.', dir=scratch)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.model = self.root/'model'
        self.model.write_bytes(b'SYNTHETIC NONEXECUTABLE TEST FIXTURE')
        self.model_sha = a.sha(self.model)
        (self.root/'coremark.img').write_bytes(b'SYNTHETIC MEDIA')
        (self.root/'rom').mkdir()
        for name in ('boot0.rom', 'boot1.rom'):
            (self.root/'rom'/name).write_bytes(name.encode())
        self.console = fixture(ticks=428000000, iterations=900).rstrip('\n')
        self.log = ('[VGATEXT @1]\n  |booting\n'
                    '[VEN-PERF] cycle=430000000 retires=120 clocks=429999637 u=90 v=30\n'
                    '[VGATEXT @430000437]\n' +
                    '\n'.join('  |'+line for line in self.console.splitlines())+'\n')
        (self.root/'stop.request').touch()
        args = [str(self.model), '--ide', str(self.root/'coremark.img'),
                '--rate', '40000000', '--rate-rtc', '40000000', '--rate-vga', '80000000',
                '--mem', '16', '--cycles', '450000000', '--ven-perf-every', '1000000',
                '--vgatext-every', '1000000', '--stop-request', str(self.root/'stop.request')]
        self.native = dict(pid=99999999, exe=str(self.model), argv=args, affinity=[15])
        pins = {str(p): a.sha(p) for p in (
            Path(a.__file__).resolve().with_name('check_result.py'),
            self.root/'rom/boot0.rom', self.root/'rom/boot1.rom')}
        self.started = dict(argv=args, cpu=15, model_sha256=self.model_sha,
            cold_reset=True, snapshots=False, guest_modifications=False, seed='performance',
            pins=pins, invocation='f'*32, wall_seconds_cap=3600,
            reference=dict(native_exit=33, iterations=900, crcs=CRCS,
                           disk_sha256=a.sha(self.root/'coremark.img')))
        self.closed = dict(passed=True, error=None, native_exit=0, pins_unchanged=True,
            pipe_eof=True, all_children_reaped=True, seconds=3500, native=self.native,
            invocation='f'*32, memory_events={'oom':'0', 'oom_kill':'0'}, last_u=90, last_v=30,
            result=check(self.console, reference_crcs=CRCS, iterations=900,
                         require_valid_duration=True))
        self.owner = dict(ActiveState='active', SubState='exited', Result='success',
                         ExecMainStatus='0', InvocationID='f'*32, MainPID='0')

    def run_audit(self):
        (self.root/'run.log').write_text(self.log)
        self.closed.update(captured_bytes=len(self.log.encode()),
                           captured_sha256=a.sha(self.root/'run.log'))
        for name, value in (('native',self.native), ('started',self.started), ('closed',self.closed)):
            (self.root/(name+'.json')).write_text(json.dumps(value))
        owner = '\n'.join(k+'='+v for k,v in self.owner.items())
        with patch.object(a.subprocess, 'check_output', return_value=owner):
            return a.audit(self.root, 'synthetic-test.service', self.model_sha)

    def test_complete_seed_is_not_board_or_gameplay_acceptance(self):
        result = self.run_audit()
        self.assertTrue(result['duration_valid'])
        self.assertEqual(result['ticks'], 428000000)
        self.assertFalse(result['standard_suite'])
        self.assertFalse(result['physical_board'])
        self.assertIsNone(result['current_gameplay_ipc'])

    def test_duplicate_identical_complete_screens_allowed(self):
        self.log += '[VGATEXT @430000438]\n' + '\n'.join(
            '  |'+line for line in self.console.splitlines())+'\n'
        self.run_audit()

    def test_no_completion_assembled_across_screens(self):
        self.log = self.log.replace('  |Total ticks', '[VGATEXT @2]\n  |Total ticks')
        with self.assertRaises(ValueError): self.run_audit()

    def test_crc_corruption(self):
        self.log = self.log.replace('0xe714','0x0000')
        with self.assertRaises(ValueError): self.run_audit()

    def test_retirement_total_mismatch(self):
        self.log = self.log.replace('retires=120','retires=121')
        with self.assertRaises(AssertionError): self.run_audit()

    def test_no_v_activity(self):
        self.log = self.log.replace('u=90 v=30','u=120 v=0')
        self.closed.update(last_u=120,last_v=0)
        with self.assertRaises(AssertionError): self.run_audit()

    def test_running_supervisor_rejected(self):
        self.owner['SubState']='running'
        with self.assertRaises(AssertionError): self.run_audit()

    def test_wrong_supervisor_invocation(self):
        self.owner['InvocationID']='e'*32
        with self.assertRaises(AssertionError): self.run_audit()

    def test_timeout_is_not_completion(self):
        self.closed['native_exit']=124
        with self.assertRaises(AssertionError): self.run_audit()

    def test_oom_is_not_completion(self):
        self.closed['memory_events']['oom']='1'
        with self.assertRaises(AssertionError): self.run_audit()

    def test_snapshot_rejected(self):
        self.started['snapshots']=True
        with self.assertRaises(AssertionError): self.run_audit()

    def test_wrong_native_cpu(self):
        self.native['affinity']=[16]
        with self.assertRaises(AssertionError): self.run_audit()

    def test_missing_eof(self):
        self.closed['pipe_eof']=False
        with self.assertRaises(AssertionError): self.run_audit()

    def test_modified_pinned_rom(self):
        (self.root/'rom/boot0.rom').write_bytes(b'changed')
        with self.assertRaises(AssertionError): self.run_audit()

    def test_missing_host_stop(self):
        (self.root/'stop.request').unlink()
        with self.assertRaises(AssertionError): self.run_audit()

    def test_native_fault_after_complete_console(self):
        self.log += '%Fatal: late failure\n'
        with self.assertRaises(AssertionError): self.run_audit()


if __name__ == '__main__': unittest.main()
