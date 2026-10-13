"""Exact branch-flag transfer and fail-closed timing admission, not acceptance."""
import ast
import os
from pathlib import Path
import unittest

import build_prime_reg_flags_soc as native
import freeze_prime_reg_flags_rk_candidate as freeze
import prepare_prime_reg_flags_synthesis as timing
import run_prime_reg_flags_regressions as regressions
import run_prime_cs_regressions as prior_regressions

ROOT=Path(os.environ.get('PRIME_REG_ROOT',
    '/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI')).resolve(strict=True)


class Transfer(unittest.TestCase):
    def test_exact_six_input_transform(self):
        name='rtl/core/core_mem_chain.svh'
        self.assertEqual(native.CHANGES,[name])
        inputs={n:(ROOT/'prime-cs-soc-r1/source/rtl/core'/n).read_text() for n in native.recipe.PARENTS}
        before=inputs['core_mem_chain.svh'].encode()
        after=(ROOT/'prime-reg-core-r1/candidate'/name).read_bytes()
        self.assertEqual(native.recipe.transform(inputs).encode(),after)
        self.assertTrue(freeze.check_delta('ventium/'+name,before,after))
        for bad in (before,after+b'\n'):
            with self.assertRaises(Exception):freeze.check_delta('ventium/'+name,before,bad)
        with self.assertRaises(Exception):freeze.check_delta('ventium/'+name,before+b'\n',after)
        for n in inputs:
            drift=dict(inputs);drift[n]+='\n'
            with self.assertRaises(ValueError):native.recipe.transform(drift)

    def test_no_second_delta_or_inherited_acceptance(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/core/core.sv',b'x',b'x'))
        with self.assertRaises(Exception):freeze.check_delta('ventium/rtl/core/core.sv',b'x',b'y')
        for marker in ('len(hw) == len(set(hw)) == 158','compiled == 170','core_mhz=40',
                       'standard_suite=False, hardware_acceptance=False',"'prime_cs_timing'",
                       "'six-source flag contract drift'"):
            self.assertIn(marker,freeze.text)

    def test_native_build_and_admission_preserved(self):
        def function(source,name):
            return ast.dump(next(n for n in ast.parse(source).body
                                 if isinstance(n,ast.FunctionDef) and n.name==name))
        original=native.original.read_text()
        self.assertEqual(function(original,'regressions'),function(native.text,'regressions'))
        without_cap=native.text.replace('    command=bound_build(command)\n','')
        for start,end in (('    shared=','    hosts='),('    command=','    for p in (*files,')):
            self.assertEqual(original.split(start)[1].split(end)[0],without_cap.split(start)[1].split(end)[0])
        for marker in ('return base.build(root)','pins.update(admit_flags(core))','len(shared)==102'):
            self.assertIn(marker,native.text)
        pins=native.admit_flags(ROOT/'prime-reg-core-r1')
        self.assertIn(str(ROOT/'prime-reg-core-audit-r1.json'),pins)

    def test_build_cap_preserves_all_native_arguments(self):
        command=[str(native.base.REPO/'tools/build_scope.sh'),'--','taskset','-c','0-31',
                 '/tools/verilator/v5.046/bin/verilator','+define+VEN_FE_PIPE','-CFLAGS','-O2 -g0']
        capped=native.bound_build(command)
        self.assertEqual(capped[:2],command[:2])
        self.assertEqual(capped[6:],command[2:])
        self.assertIn('MemoryMax=10G MemorySwapMax=2G',capped[4])
        self.assertIn('exit 70',capped[4])
        self.assertTrue(capped[4].endswith('exec "$@"'))
        with self.assertRaises(AssertionError):native.bound_build(command[2:])

    def test_extended_regression_plan_preserved(self):
        def function(source,name):
            rows=[n for n in ast.parse(source).body if isinstance(n,ast.FunctionDef) and n.name==name]
            self.assertEqual(len(rows),1)
            return ast.dump(rows[0])
        self.assertEqual(function(regressions.derive(),'plan'),
                         function(prior_regressions.derive(),'plan'))

    def test_timing_guards_and_exact_parent(self):
        original={}
        for name,digest in timing.TEMPLATES.items():
            self.assertEqual(native.sha(ROOT/name),digest)
            original[name]=(ROOT/name).read_text()
        result=timing.derive(original,timing.CHANGES)
        self.assertEqual(len(result),5)
        synth=result['prime-reg-synthesis-r1/run.py']
        clock=result['prime-reg-clock-r1/run.py']
        for marker in ('changes='+repr(native.CHANGES),"assert core['changes']==changes",
                       "assert prepared['added_defines']==[]",'assert shutil.disk_usage(root).free > 6*gib',
                       "assert all(r['parent_ticks']==r['candidate_ticks']",
                       "assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']"):
            self.assertIn(marker,synth)
        self.assertIn(timing.PARENT_DCP,clock)
        self.assertIn(str(ROOT/'prime-cs-synthesis-r1'),clock)
        self.assertIn('(-4.448)',result['prime-reg-clock-r1/audit_closed.py'])
        self.assertIn(timing.PARENT_MANIFEST,result['prime-reg-synthesis-r1/audit_closed.py'])
        for key in ('synthesis','clock'):
            self.assertIn("manifest['variant'] == 'prime_reg_flags_timing'",result['prime-reg-'+key+'-r1/run.py'])
        for before,after in (("VENTIUM_VIVADO_MEMORY_SWAP_MAX='4G'","VENTIUM_VIVADO_MEMORY_SWAP_MAX='8G'"),
                             ('if free < 4*gib:','if free < 1*gib:'),
                             ('memory+swap > 11*gib','memory+swap > 20*gib')):
            with self.assertRaises(AssertionError):
                timing.clock_guarded(clock.replace(before,after),original['prime-cs-clock-swap4-r1/run.py'])


if __name__=='__main__':unittest.main()
