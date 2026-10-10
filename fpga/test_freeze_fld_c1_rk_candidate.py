import unittest

import freeze_fld_c1_rk_candidate as freeze
from test_freeze_code_payload_rk_candidate import CodePayloadProfile


class LoadC1Freeze(unittest.TestCase):
    def setUp(self):
        fixture = CodePayloadProfile()
        fixture.setUp()
        self.native = fixture.sim
        self.hardware = fixture.parent[:-3]+['VEN_L1D_CODE_PAYLOAD_SELECT']+fixture.parent[-3:]
        # Replace anonymous fixture prefix with the actual required feature names.
        required = ['VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
                    'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT', 'VEN_FP_SHARED']
        for i, name in enumerate(required):
            self.hardware[self.hardware.index('BASE_'+str(i))] = name
            self.native[self.native.index('BASE_'+str(i))] = name

    def test_no_profile_change(self):
        self.assertEqual(freeze.profile(self.hardware, self.native), self.hardware)

    def test_missing_replaced_or_duplicate_native_feature(self):
        for name in self.native:
            for replacement in ([], ['VEN_UNKNOWN'], ['VEN_UOPCACHE'], ['VEN_CACHE_HALF']):
                with self.subTest(name=name, replacement=replacement), self.assertRaises(freeze.FreezeError):
                    freeze.profile(self.hardware, [x for x in self.native if x != name]+replacement)
        with self.assertRaises(freeze.FreezeError):
            freeze.profile(self.hardware, self.native+self.native[:1])

    def test_matching_removal_of_required_feature(self):
        for name in ('VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_FP_SHARED'):
            with self.subTest(name=name), self.assertRaises(freeze.FreezeError):
                freeze.profile([x if x != name else 'VEN_UNKNOWN' for x in self.hardware],
                               [x if x != name else 'VEN_UNKNOWN' for x in self.native])

    def test_exact_single_rtl_delta(self):
        self.assertTrue(freeze.check_delta(freeze.TOP, 'old', freeze.TOP_SHA))
        self.assertFalse(freeze.check_delta('rtl/core/core.sv', 'same', 'same'))
        for name, digest in ((freeze.TOP, 'unknown'), ('rtl/core/core.sv', freeze.TOP_SHA),
                             ('flow/create_project.tcl', freeze.TOP_SHA)):
            with self.subTest(name=name), self.assertRaises(freeze.FreezeError):
                freeze.check_delta(name, 'old', digest)


if __name__ == '__main__':
    unittest.main()
