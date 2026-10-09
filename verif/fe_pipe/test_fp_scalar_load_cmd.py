"""Fail-closed transformation checks, not RTL or performance acceptance."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('prepare', HERE/'prepare-fp-scalar-load-cmd.py')
prepare=importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class Guards(unittest.TestCase):
    def test_event_fixture_transform(self):
        es=importlib.util.spec_from_file_location('events', HERE/'prepare-fp-scalar-load-events.py')
        events=importlib.util.module_from_spec(es);es.loader.exec_module(events)
        source=(HERE/'fp-scalar-events.S').read_text()
        output=events.transform(source)
        for old in events.CHANGES:
            with self.subTest(anchor=old), self.assertRaises(ValueError):
                events.transform(source.replace(old,''))
        self.assertIn('cmpl $hot_after,(%esp)',output)
        self.assertIn('cmpl $hot_op,(%esp)',output)
        self.assertIn('cmpl $1,0x2110',output)
        self.assertIn('fcoml 0x2100',output)

    def test_fault_fixture_transform(self):
        fspec=importlib.util.spec_from_file_location('fault', HERE/'prepare-fp-scalar-load-fault.py')
        fault=importlib.util.module_from_spec(fspec);fspec.loader.exec_module(fault)
        source=(HERE/'fp-mem64-fault.S').read_text()
        output=fault.transform(source)
        for old in fault.CHANGES:
            with self.subTest(anchor=old), self.assertRaises(ValueError):
                fault.transform(source.replace(old,''))
        self.assertIn('#define SOURCE 0x400ffe',output)
        self.assertIn('#define SOURCE 0x400ffc',output)
        self.assertIn('cmpl $older_op,0x304c',output)
        self.assertIn('cmpl $source_op,4(%esp)',output)
        self.assertIn('fcoml (%ebx)',output)
        self.assertIn('fiaddl (%ebx)',output)

    def test_anchor_and_reapplication(self):
        for value in ('', prepare.ANCHOR*2, prepare.transform(prepare.ANCHOR)):
            with self.subTest(value=value), self.assertRaises(ValueError):
                prepare.transform(value)

    def test_inactive_profile_and_old_classes(self):
        actual=prepare.transform(prepare.ANCHOR)
        head, rest=actual.split('`ifdef '+prepare.FLAG+'\n')
        _, tail=rest.split('`endif\n')
        self.assertEqual(''.join((head+tail).split()), ''.join(prepare.ANCHOR.split()))
        self.assertIn("fctrl[5:0] == 6'h3f", actual)
        self.assertIn('!fstat[7]', actual)
        self.assertNotIn('FX_FST', actual)
        self.assertNotIn('FX_FIST', actual)

    def test_disjoint_copy_and_existing_output(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as d:
            root=Path(d);source=root/'source';p=source/'rtl/core/core.sv'
            p.parent.mkdir(parents=True);p.write_text(prepare.ANCHOR)
            (source/'keep').write_text('keep')
            with self.assertRaises(ValueError):prepare.prepare(source,source/'nested')
            result=prepare.prepare(source,root/'candidate')
            self.assertEqual(p.read_text(),prepare.ANCHOR)
            self.assertEqual((root/'candidate/keep').read_text(),'keep')
            self.assertFalse(result['production'])
            with self.assertRaises(FileExistsError):prepare.prepare(source,root/'candidate')


if __name__=='__main__':unittest.main()
