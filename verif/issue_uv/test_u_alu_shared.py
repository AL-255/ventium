"""Exact source/ownership checks; native result/flag comparisons are separate."""
import hashlib
import os
from pathlib import Path
import unittest
from prepare_u_alu_shared import ANCHOR, EDITS, HELPER, NEW, OLD, PARENT, transform


class Recipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source=Path(os.environ['U_ALU_PARENT']).read_text()

    def test_exact_scope_and_reverse(self):
        self.assertEqual(hashlib.sha256(self.source.encode()).hexdigest(),PARENT)
        changed=transform(self.source)
        for old,new in reversed(EDITS): changed=changed.replace(new,old,1)
        self.assertEqual(changed,self.source)
        self.assertEqual(self.source.split(ANCHOR)[0],transform(self.source).split(HELPER)[0])

    def test_drift_and_reapplication_rejected(self):
        for bad in (self.source+'\n',transform(self.source),self.source.replace('eflags[0]','eflags[1]')):
            with self.assertRaises(ValueError):transform(bad)

    def test_no_shift_or_interface_change(self):
        changed=transform(self.source)
        boundary='    // task #56 step I:'
        self.assertEqual(self.source.split(boundary)[1],changed.split(boundary)[1])
        self.assertEqual(changed.count(NEW),1)
        self.assertNotIn(OLD,changed)
        self.assertNotIn('BAD_SHARED',changed)
        self.assertNotIn('always_ff',changed)
        self.assertIn('cpos=(width==1)?8:((width==2)?16:32);',HELPER)
        self.assertIn('fl[7]=sbit(res,width);',HELPER)


if __name__=='__main__':unittest.main()
