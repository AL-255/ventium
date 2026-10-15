import os
from pathlib import Path
import unittest

import prepare_underflow as recipe


class UnderflowRecipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.before=(Path(os.environ['QEMU_UNDERFLOW_PARENT'])/recipe.HELPER).read_text()
        cls.after=recipe.transform(cls.before)

    def test_exact_single_helper_change(self):
        self.assertEqual(self.after.replace(recipe.ADDITION,''),self.before)
        for marker in ('static void helper_fprem_common(','\nvoid helper_fprem1('):
            self.assertEqual(self.after.count(marker),1)
        start=self.before.index('static void helper_fprem_common(')
        self.assertEqual(self.before[:start],self.after[:start])
        self.assertEqual(self.before.split('\nvoid helper_fprem1(',1)[1],
                         self.after.split('\nvoid helper_fprem1(',1)[1])

    def test_preserve_abort_and_precision_restore_order(self):
        body=self.after.split('static void helper_fprem_common(',1)[1].split('\nvoid helper_fprem1(',1)[0]
        self.assertLess(body.index(recipe.ADDITION),body.index('\ndone:'))
        self.assertEqual(body.count('goto done;'),4)
        self.assertLess(body.index('floatx80_scalbn(ST0, 24576'),
                        body.index('set_floatx80_rounding_precision(precision'))
        self.assertNotIn('float_flag_inexact',recipe.ADDITION)

    def test_parent_drift_and_reapplication_rejected(self):
        for text in (self.before+'\n',self.after,self.before.replace('24576','24575')):
            if text==self.before:continue
            with self.assertRaises(ValueError):recipe.transform(text)


if __name__=='__main__':unittest.main()
