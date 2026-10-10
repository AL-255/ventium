#!/usr/bin/env python3
"""Host-only matrix/expectation and fail-closed repair tests; not RTL passes."""
import copy
import importlib.util
from pathlib import Path
import unittest

def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

o=load('run_fst_register_observe')
repair=load('prepare_fst_register')

def case(**kwargs):
    c=dict(top=0,sti=1,pop=0,source_empty=0,destination_empty=0,masked=1,seed=0)
    c.update(kwargs)
    return c

class FSTTests(unittest.TestCase):
    def test_matrix(self):
        self.assertEqual(len(o.cases()),240)
        all_cases=o.cases(True)
        self.assertEqual(len(all_cases),1920)
        self.assertEqual(len({o.metadata(c) for c in all_cases}),1920)
        self.assertTrue(all(c['sti']!=0 or c['source_empty']==c['destination_empty'] for c in all_cases))

    def test_empty_destination_is_not_source(self):
        c=case(sti=7,destination_empty=1,masked=0,seed=1)
        e=o.expected(c)
        self.assertEqual(e['fstat'],0)
        self.assertEqual(e['ftag'],0)
        self.assertEqual(e['registers'][7],0x40028000000000000000)

    def test_masked_source_fault(self):
        e=o.expected(case(source_empty=1,pop=1))
        self.assertEqual(e['fstat'],0x841)
        self.assertEqual(e['ftag'],0xb)
        self.assertEqual(e['registers'][0],o.INDEFINITE)

    def test_unmasked_source_fault_suppresses_copy_and_pop(self):
        e=o.expected(case(source_empty=1,pop=1,masked=0))
        self.assertEqual(e['fstat'],0x80c1)
        self.assertEqual(e['ftag'],3)
        self.assertEqual(e['top'],0)
        self.assertEqual(e['registers'][1],0x4001e000000000000000)

    def test_self_copy_then_pop_is_empty(self):
        e=o.expected(case(sti=0,pop=1))
        self.assertEqual(e['ftag'],3)
        self.assertEqual(e['top'],1)

    def test_top_wrap(self):
        e=o.expected(case(top=7,pop=1))
        self.assertEqual(e['top'],0)
        self.assertEqual(e['ftag'],0xc000)
        self.assertEqual(e['registers'][0],0x40028000000000000000)

    def test_each_defined_status_bit_is_checked(self):
        e=o.expected(case())
        for bit in range(16):
            a=copy.deepcopy(e); a['fstat']^=1<<bit
            self.assertEqual('fstat_defined' in o.differences(a,e),bool(o.DEFINED_STATUS&(1<<bit)))

    def test_live_values_and_empty_tags_are_checked(self):
        e=o.expected(case(pop=1))
        a=copy.deepcopy(e); a['registers'][0]^=1
        self.assertIn('st0',o.differences(a,e))
        a=copy.deepcopy(e); a['registers'][7]^=1
        self.assertEqual(o.differences(a,e),[])
        a['ftag']^=1
        self.assertIn('ftag',o.differences(a,e))

    def test_assembly_uses_only_isa_state_setup(self):
        items=o.cases(True); asm=o.assembly(items)
        self.assertEqual(asm.count('fnstenv env'),1920)
        self.assertEqual(asm.count('fnsave rows+'),1920)
        self.assertEqual(asm.count('fincstp'),6720)
        self.assertEqual(asm.count('int $0x80'),2)

    def test_repair_rejects_ambiguous_or_missing_anchor(self):
        for text in ('','x x'):
            with self.assertRaises(ValueError): repair.once(text,'x','y')
        self.assertEqual(repair.once('x','x','y'),'y')

if __name__=='__main__': unittest.main()
