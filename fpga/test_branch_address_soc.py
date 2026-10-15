import os
from pathlib import Path
import unittest

import build_branch_address_soc as transfer
import freeze_branch_address_rk_candidate as freeze


class Transfer(unittest.TestCase):
    def setUp(self):
        self.parent=Path(os.environ['BRANCH_ADDRESS_SOC_PARENT'])
        self.core=Path(os.environ['BRANCH_ADDRESS_CORE'])

    def test_entire_shared_closure_and_composed_repairs(self):
        shared=sorted(str(p.relative_to(self.parent)) for p in self.parent.rglob('*')
            if p.is_file() and p.relative_to(self.parent).parts[0] in ('rtl','fp_shared')
            and (self.core/p.relative_to(self.parent)).is_file())
        self.assertEqual(len(shared),102)
        changed=[n for n in shared if transfer.sha(self.parent/n)!=transfer.sha(self.core/n)]
        self.assertEqual(changed,transfer.CHANGES)
        self.assertEqual(len(changed),4)
        for n in changed:
            original=(self.parent/n).read_text()
            self.assertEqual(transfer.transform(n,original),(self.core/n).read_text())
            self.assertTrue(freeze.check_delta('ventium/'+n,original.encode(),(self.core/n).read_bytes()))
            with self.assertRaises(Exception):freeze.check_delta('ventium/'+n,original.encode(),original.encode())
            with self.assertRaises(ValueError):transfer.transform(n,original+'\n')
        self.assertNotIn('u_fetch_metadata',(self.core/'rtl/core/core.sv').read_text())

    def test_omitting_underflow_is_not_a_matched_transfer(self):
        n='rtl/fpu/fpu_srt_div.sv'; original=(self.parent/n).read_text()
        partial=transfer.exceptions.transform(transfer.numeric.transform(original),n)
        self.assertNotEqual(partial,(self.core/n).read_text())
        with self.assertRaises(Exception):freeze.check_delta('ventium/'+n,original.encode(),partial.encode())
        with self.assertRaises(Exception):freeze.check_delta('ventium/rtl/core/decode.sv',b'old',b'new')
        self.assertFalse(freeze.check_delta('unchanged',b'same',b'same'))
        with self.assertRaises(ValueError):transfer.transform('rtl/core/decode.sv','')


if __name__=='__main__':unittest.main()
