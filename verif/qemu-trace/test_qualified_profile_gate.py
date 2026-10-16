"""Retain failed verdicts and reject changed timing/diagnostic-mode evidence."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import run_qualified_profile_gate as gate


class GateAnalysis(unittest.TestCase):
    def setUp(self):
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertEqual(Path(os.environ['TMPDIR']).resolve(), scratch)
        self.temp = tempfile.TemporaryDirectory(prefix='reference-gate-test.', dir=scratch)
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.work, self.prior = root/'work', root/'prior'
        self.work.mkdir(); self.prior.mkdir()
        fmt = gate.tracefmt
        rows = [fmt.header('rtl','cycle'),
                fmt.cycle_record(0,0x1000,2,'U',True),
                fmt.cycle_record(1,0x1001,2,'V',True)]
        self.cycle = '\n'.join(fmt.dumps(r) for r in rows)+'\n'
        for n in range(20):
            name = f'kernel{n}.cycle_rtl.vtrace'
            for folder in (self.work,self.prior):
                (folder/name).write_text(self.cycle)
            (self.work/name).with_suffix('.argv').write_bytes(b'tb\0--cycle\0--l1-axi\0')
        (self.work/'example.func.result').write_text('FUNC|example|int|PASS|diff-clean|0\n')
        rows = [fmt.header('rtl','func')]+[fmt.func_record(n,0x1000+n,2,
                dict.fromkeys(fmt.GPR_KEYS,0),dict.fromkeys(fmt.SEG_KEYS,0)) for n in range(10)]
        (self.work/'example.func_rtl.vtrace').write_text('\n'.join(fmt.dumps(r) for r in rows)+'\n')
        (self.work/'example.func_rtl.log').write_text(
            '  retires 10 (U=3  pairedV=7)\n    6  PAIRED             (U + V retired)\n')

    def test_complete_matching_cycle_streams_and_actual_pair_counter(self):
        result=gate.analyze(self.work,self.prior)
        self.assertTrue(result['cycle_records_unchanged'])
        self.assertTrue(result['cycle_argv_checked'])
        self.assertEqual(result['functional_passes'],1)
        self.assertEqual(result['functional_v_retired'],7)
        self.assertEqual(result['functional_u_retired'],3)
        self.assertEqual(result['functional_fast_issue_pairs'],6)
        self.assertEqual(sum(r['v_retired'] for r in result['cycles']),20)

    def test_failed_functional_verdict_is_not_converted_to_pass(self):
        (self.work/'example.func.result').write_text('FUNC|example|int|FAIL|field eax|0\n')
        result=gate.analyze(self.work,self.prior)
        self.assertEqual(result['functional_passes'],0)
        self.assertEqual(result['functional'][0]['detail'],'field eax')

    def test_changed_clock_and_missing_stream_are_visible(self):
        path=self.work/'kernel0.cycle_rtl.vtrace'
        rows=gate.tracefmt.read_trace(str(path)).records
        rows[0]['cyc']=3
        path.write_text(gate.tracefmt.dumps(gate.tracefmt.header('rtl','cycle'))+'\n'+
                        '\n'.join(gate.tracefmt.dumps(r) for r in rows)+'\n')
        self.assertFalse(gate.analyze(self.work,self.prior)['cycle_records_unchanged'])
        path.unlink()
        self.assertFalse(gate.analyze(self.work,self.prior)['cycle_argv_checked'])

    def test_debug_controls_do_not_qualify_uv_acceptance(self):
        for flag in (b'--dbg-step',b'--dbg-bp',b'--no-trace',b'--cycle-func'):
            with self.subTest(flag=flag):
                (self.work/'kernel0.cycle_rtl.argv').write_bytes(b'tb\0--cycle\0--l1-axi\0'+flag+b'\0')
                self.assertFalse(gate.analyze(self.work,self.prior)['cycle_argv_checked'])

    def test_missing_or_inconsistent_total_retire_counters_are_rejected(self):
        for text in ('', 'retires 10 (U=4 pairedV=7)\n', 'retires 9 (U=2 pairedV=7)\n'):
            with self.subTest(text=text):
                (self.work/'example.func_rtl.log').write_text(text)
                with self.assertRaises(ValueError):gate.analyze(self.work,self.prior)


class ShellSelection(unittest.TestCase):
    def run_hook(self, build=None):
        text=(gate.REPO/'verif/verify.sh').read_text()
        start=text.index('REFS="$ROOT/ventium-refs/07-p5-emulation-harness"')
        end=text.index('export ISA_VERIFY=',start)
        env=dict(os.environ,ROOT=str(gate.REPO),QEMU='/unqualified/emulator')
        for key in ('VTM_QEMU_PROFILE_BUILD','VTM_QEMU_GDB_PREEXIT'):
            env.pop(key,None)
        if build is not None:env['VTM_QEMU_PROFILE_BUILD']=build
        return subprocess.run(['bash','-uc',text[start:end]+'\nprintf "%s|%s" "$QEMU" "${VTM_QEMU_GDB_PREEXIT:-0}"'],
                              env=env,capture_output=True,text=True,timeout=20)

    def test_default_reference_is_unchanged_and_not_environment_overridden(self):
        result=self.run_hook()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,str(gate.REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386')+'|0')

    def test_bad_explicit_profile_does_not_fall_back(self):
        result=self.run_hook('/nonexistent/ventium-qualified-reference')
        self.assertEqual(result.returncode,1)
        self.assertIn('qualified reference validation failed',result.stderr)
        self.assertNotIn('|0',result.stdout)


if __name__=='__main__': unittest.main()
