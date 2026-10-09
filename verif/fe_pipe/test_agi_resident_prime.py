"""Fail-closed recipe/fixture tests, not architectural acceptance."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
def module(name):
    spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'))
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m


class Guards(unittest.TestCase):
    def test_recipe_exact_anchors(self):
        m=module('prepare-agi-resident-prime');source='\n'.join(m.CHANGES)
        m.transform(source)
        for anchor in m.CHANGES:
            for bad in (source.replace(anchor,''),source+'\n'+anchor):
                with self.assertRaises(ValueError):m.transform(bad)
        with self.assertRaises(ValueError):m.transform(m.transform(source))

    def test_recipe_disjoint_pins(self):
        m=module('prepare-agi-resident-prime')
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as d:
            root=Path(d);source=root/'source';p=source/m.TARGET
            p.parent.mkdir(parents=True);p.write_text('\n'.join(m.CHANGES))
            (source/'keep').write_text('unchanged')
            with self.assertRaises(ValueError):m.prepare(source,source/'nested')
            result=m.prepare(source,root/'candidate')
            self.assertFalse(result['production'])
            self.assertEqual((root/'candidate/keep').read_text(),'unchanged')
            self.assertEqual((root/'candidate'/m.LEAF).read_bytes(),
                             (HERE/'core_agi_resident_prime.svh').read_bytes())
            self.assertEqual(p.read_text(),'\n'.join(m.CHANGES))
            with self.assertRaises(FileExistsError):m.prepare(source,root/'candidate')

    def test_fixture_has_distinct_values_and_actual_dependencies(self):
        m=module('prepare-agi-prime-fixture')
        text=m.transform((HERE/'ref-operand-prime.S').read_text())
        for witness in ('movl $(1+\\displacement/64)','leal \\displacement(%ebp),%edi',
                        'movl (%edi),%eax','movl (%ebp,%edi,4),%eax',
                        'movl (%edi),%edi','cmpl $640,%eax','cmpl $4,%eax'):
            self.assertIn(witness,text)
        with self.assertRaises(ValueError):m.transform(text)

    def test_oracle_driver_preserves_complete_comparison(self):
        m=module('run-agi-resident-prime')
        source=(HERE/'run-ref-operand-prime.py').read_text()
        text=m.transform(source);compile(text,'<agi-driver>','exec')
        for check in ('compare_complete(gold,trace,log)==0',"len(pairs)==64",
                      "b['total_clocks']<=a['total_clocks']","case[0]>=6",
                      "'--max-cycles','3000000'","'--quiesce','200000'",
                      "'VEN_REF_OPERAND_PRIME' in profiles['control']"):
            self.assertIn(check,text)
        with self.assertRaises(ValueError):m.transform(text)
        with self.assertRaises(ValueError):m.transform('')

    def test_fault_fixture_and_unchanged_oracle(self):
        m=module('prepare-agi-prime-fault')
        text=m.transform((HERE/'fp-mem64-fault.S').read_text())
        for check in ('movl %ebx,%edx\nsource_op:', 'movb (%edx),%al',
                      'movl (%edx),%esi','addl (%edx),%esi','cmpl $7,%esi',
                      'cmpl $source_op,4(%esp)','cmpl $0x401000,%eax'):
            self.assertIn(check,text)
        self.assertNotIn('%sil',text)
        m=module('run-agi-prime-fault')
        source=(HERE/'run-fp-mem64-queue.py').read_text()
        text=m.transform(source);compile(text,'<fault-driver>','exec')
        for check in ('compare_complete(gold, trace, log) == 0',
                      'check_faultlog.check_counts', 'VEN_RAW_AGI_PRIME'):
            self.assertIn(check,text)
        with self.assertRaises(ValueError):m.transform(text)

    def test_event_fixture_and_complete_oracle(self):
        m=module('prepare-agi-prime-events')
        text=m.transform((HERE/'fp-scalar-events.S').read_text())
        for check in ('cmpl $hot_load,(%esp)','testl $0x4000,%eax',
                      'movl $0x2100,%ebx','movl (%ebx),%eax',
                      'cmpl $0,0x2004','pushl $hot_op\n    movl $0,%eax\n    iretl'):
            self.assertIn(check,text)
        m=module('run-agi-prime-events')
        text=m.transform((HERE/'run-fp-scalar-events.py').read_text())
        compile(text,'<agi-events>','exec')
        for check in ('compare_complete(gold, trace, log) == 0', 'len(hits) == 8',
                      "==symbols['nm_handler']])==0", 'check_faultlog.check_counts',
                      'FETCHDBG:AGIPRIME'):
            self.assertIn(check,text)
        with self.assertRaises(ValueError):m.transform(text)


if __name__=='__main__':unittest.main()
