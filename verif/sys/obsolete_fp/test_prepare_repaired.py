import os
from pathlib import Path
import unittest

import prepare_repaired as recipe


class ObsoleteRecipe(unittest.TestCase):
    def test_scope_and_trap_order(self):
        parent=Path(os.environ['OBSOLETE_PARENT'])/'rtl/core'
        after={n:recipe.transform((parent/n).read_text(),n) for n in recipe.PARENTS}
        decoder=after['decode_stages.sv']
        self.assertEqual(decoder.count("8'hE0, 8'hE1, 8'hE4: d_fxop=FX_NONE;"),1)
        dispatch=after['core_fetch_decode.svh']
        a=dispatch.index('else if (d_is_x87 && (creg0[2] || creg0[3]))')
        b=dispatch.index('else if (d_is_x87 && d_fxop == FX_NONE)')
        c=dispatch.index('else if ((d_is_fwait || (d_is_x87 && d_fxop == FX_FNOP)')
        self.assertLess(a,b); self.assertLess(b,c)
        for name in recipe.PARENTS:
            for wrong in ((parent/name).read_text()+'\n',after[name]):
                with self.assertRaises(ValueError): recipe.transform(wrong,name)


if __name__ == '__main__': unittest.main()
