"""Exact three-file hardware transfer, not merely the latest core edit."""
import os
from pathlib import Path
import unittest

import build_fetch_metadata_soc as build
import freeze_fetch_metadata_rk_candidate as freeze


class Transfer(unittest.TestCase):
    def setUp(self):
        self.parent=Path(os.environ['FETCH_METADATA_PC_PARENT'])/'source'
        self.core=Path(os.environ['FETCH_METADATA_CORE'])/'candidate'

    def test_all_composed_repairs(self):
        self.assertEqual(build.CHANGES,['fp_shared/ven_fp_top.sv','rtl/core/core.sv','rtl/fpu/fpu_srt_div.sv'])
        for name in build.CHANGES:
            before=(self.parent/name).read_text();after=(self.core/name).read_text()
            self.assertEqual(build.transform(name,before),after)
            self.assertTrue(freeze.check_delta('ventium/'+name,before.encode(),after.encode()))
            for bad in (before+'\n',after):
                with self.assertRaises(ValueError):build.transform(name,bad)
            with self.assertRaises(Exception):freeze.check_delta('ventium/'+name,before.encode(),before.encode())

    def test_reject_omitted_fp_exception_fix(self):
        name='rtl/fpu/fpu_srt_div.sv';before=(self.parent/name).read_text()
        partial=build.numeric.transform(before)
        with self.assertRaises(Exception):freeze.check_delta('ventium/'+name,before.encode(),partial.encode())
        with self.assertRaises(ValueError):build.transform('rtl/core/decode_stages.sv','unexpected')
        with self.assertRaises(Exception):freeze.check_delta('ventium/rtl/core/decode_stages.sv',b'old',b'new')
        self.assertFalse(freeze.check_delta('unchanged',b'same',b'same'))


if __name__=='__main__':unittest.main()
