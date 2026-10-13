"""Exact single-file transfer/coverage admission; not FPGA acceptance."""
import ast
import os
from pathlib import Path
import unittest

import build_prime_cs_soc as native
import freeze_prime_cs_rk_candidate as freeze
import prepare_prime_cs_synthesis as timing

ROOT=Path(os.environ.get('PRIME_CS_ROOT',
    '/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI')).resolve(strict=True)


class Transfer(unittest.TestCase):
    def test_exact_rtl_transform(self):
        name='rtl/core/core.sv'
        self.assertEqual(native.CHANGES,[name])
        before=(ROOT/'prime-coherence-soc-r1/source'/name).read_bytes()
        after=(ROOT/'prime-cs-core-r1/candidate'/name).read_bytes()
        self.assertEqual(native.recipe.transform(before.decode(),name).encode(),after)
        self.assertTrue(freeze.check_delta('ventium/'+name,before,after))
        for bad in (before,after+b'\n'):
            with self.assertRaises(Exception): freeze.check_delta('ventium/'+name,before,bad)
        with self.assertRaises(ValueError): native.recipe.transform(before.decode()+'\n',name)
        with self.assertRaises(ValueError): native.recipe.transform(after.decode(),name)

    def test_no_second_file_or_inherited_acceptance(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/mem/ven_l1d.sv',b'x',b'x'))
        with self.assertRaises(Exception): freeze.check_delta('ventium/rtl/mem/ven_l1d.sv',b'x',b'y')
        for text in ('len(hw) == len(set(hw)) == 158','compiled == 170','core_mhz=40',
                     'standard_suite=False, hardware_acceptance=False',"'prime_coherence_timing'"):
            self.assertIn(text,freeze.text)

    def test_native_build_and_regression_contract_unchanged(self):
        original=native.original.read_text()
        def function(source,name):
            return ast.dump(next(n for n in ast.parse(source).body
                                 if isinstance(n,ast.FunctionDef) and n.name==name))
        self.assertEqual(function(original,'regressions'),function(native.text,'regressions'))
        for start,end in (('    shared=','    hosts='),('    command=','    for p in (*files,')):
            self.assertEqual(original.split(start)[1].split(end)[0],native.text.split(start)[1].split(end)[0])
        for marker in ('return base.build(root)',"pins.update(admit_cs(core,coverage))",'len(shared)==102'):
            self.assertIn(marker,native.text)

    def test_actual_coverage_admission(self):
        pins=native.admit_cs(ROOT/'prime-cs-core-r1',ROOT/'prime-cs-coverage-r1')
        self.assertIn(str(ROOT/'prime-cs-coverage-r1/closed.json'),pins)
        with self.assertRaises(AssertionError):
            native.admit_cs(ROOT/'prime-coherence-core-r1',ROOT/'prime-cs-coverage-r1')

    def test_timing_guards_and_exact_parent(self):
        original={}
        for name,digest in timing.TEMPLATES.items():
            self.assertEqual(native.sha(ROOT/name),digest)
            original[name]=(ROOT/name).read_text()
        result=timing.derive(original,timing.CHANGES)
        self.assertEqual(len(result),5)
        for phase in ('synthesis','clock'):
            text=result['prime-cs-'+phase+'-r1/run.py']
            timing.guarded(text,original['prime-coherence-'+phase+'-r1/run.py'])
            self.assertIn("manifest['variant'] == 'prime_cs_timing'",text)
        synth=result['prime-cs-synthesis-r1/run.py']
        for marker in ('changes='+repr(native.CHANGES),"assert core['changes']==changes",
                       "assert prepared['added_defines']==[]","assert shutil.disk_usage(root).free > 6*gib",
                       "assert all(r['parent_ticks']==r['candidate_ticks']"):
            self.assertIn(marker,synth)
        self.assertIn(timing.PARENT_DCP,result['prime-cs-clock-r1/run.py'])
        self.assertIn('(-5.344)',result['prime-cs-clock-r1/audit_closed.py'])


if __name__=='__main__': unittest.main()
