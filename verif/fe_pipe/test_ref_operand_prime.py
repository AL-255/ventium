"""Recipe fail-closed tests. Architectural acceptance is a separate gate."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('prepare',HERE/'prepare-ref-operand-prime.py')
prepare=importlib.util.module_from_spec(spec);spec.loader.exec_module(prepare)


class Guards(unittest.TestCase):
    def test_event_driver_composition(self):
        spec=importlib.util.spec_from_file_location('events',HERE/'run-ref-prime-fp-events.py')
        events=importlib.util.module_from_spec(spec);spec.loader.exec_module(events)
        for fault,integer in ((False,False),(True,False),(True,True)):
            source=(HERE/('run-fp-mem64-queue.py' if fault else 'run-fp-scalar-events.py')).read_text()
            output=events.transform(source,fault,integer)
            compile(output,'<composed-driver>','exec')
            self.assertIn('compare_complete(gold, trace, log) == 0',output)
            self.assertIn("check_faultlog.check_counts",output)
            self.assertIn('VEN_REF_OPERAND_PRIME',output)
            self.assertNotIn('VEN_FP_SCALAR_LOAD_CMD',output)
            with self.assertRaises(ValueError):events.transform(output,fault,integer)
            with self.assertRaises(ValueError):events.transform('',fault,integer)

    def test_integer_fault_fixture(self):
        spec=importlib.util.spec_from_file_location('fault',HERE/'prepare-ref-prime-int-fault.py')
        fault=importlib.util.module_from_spec(spec);spec.loader.exec_module(fault)
        source=(HERE/'fp-mem64-fault.S').read_text()
        output=fault.transform(source)
        for text in ('movsbl (%ebx),%esi','movswl (%ebx),%esi','imull (%ebx),%esi',
                     'cmpl $source_op,4(%esp)','cmpl $0x401000,%eax',
                     'cmpl $0x40000000,0x3024','movzwl 0x3044,%eax'):
            self.assertIn(text,output)
        self.assertEqual(output.count('cmpl $older_op,0x304c'),2)
        self.assertNotIn('fstl 0x3030',output)
        with self.assertRaises(ValueError):fault.transform(output)
        with self.assertRaises(ValueError):fault.transform('')

    def test_all_anchors_unique(self):
        source='\n'.join(prepare.CHANGES)
        prepare.transform(source)
        for anchor in prepare.CHANGES:
            for invalid in (source.replace(anchor,''),source+'\n'+anchor):
                with self.subTest(anchor=anchor),self.assertRaises(ValueError):
                    prepare.transform(invalid)

    def test_reapplication(self):
        source='\n'.join(prepare.CHANGES)
        with self.assertRaises(ValueError):prepare.transform(prepare.transform(source))

    def test_disjoint_and_pinned_copy(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as d:
            root=Path(d);source=root/'source';p=source/prepare.TARGET
            p.parent.mkdir(parents=True);p.write_text('\n'.join(prepare.CHANGES))
            (source/'keep').write_text('unchanged')
            with self.assertRaises(ValueError):prepare.prepare(source,source/'nested')
            result=prepare.prepare(source,root/'candidate')
            self.assertFalse(result['production'])
            self.assertEqual((root/'candidate/keep').read_text(),'unchanged')
            self.assertEqual((root/'candidate'/prepare.LEAF).read_bytes(),
                             (HERE/'core_ref_operand_prime.svh').read_bytes())
            self.assertEqual(p.read_text(),'\n'.join(prepare.CHANGES))
            with self.assertRaises(FileExistsError):prepare.prepare(source,root/'candidate')


if __name__=='__main__':unittest.main()
