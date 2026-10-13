"""Source-contract checks only; does not simulate or qualify the SMSW repair."""
import argparse
import hashlib
import json
from pathlib import Path
import unittest

import prepare


class SourceContract(unittest.TestCase):
    sources = {}

    def test_exact_scope_and_no_reapplication(self):
        for name, source in self.sources.items():
            with self.subTest(name=name):
                result = prepare.transform(source, name)
                self.assertNotEqual(source, result)
                with self.assertRaises(ValueError):
                    prepare.transform(result, name)
                with self.assertRaises(ValueError):
                    prepare.transform(source+'\n', name)
                # The only declared signals/states remain the parent's.
                self.assertEqual(source.count('always_'), result.count('always_'))
                self.assertEqual(source.count('`ifdef'), result.count('`ifdef'))

    def test_register_arm_and_memory_width(self):
        result = prepare.transform(self.sources['decode_stages.sv'], 'decode_stages.sv')
        self.assertIn(prepare.NEW_DECODE, result)
        self.assertIn("d_dst_reg=modrm_rm; d_writes_reg=1'b1;", result)
        self.assertIn("d_mem_write=1'b1; d_mem_dst=1'b1; d_w=3'd2;", result)
        self.assertEqual(result.count("d_smsw=1'b1;"), 1)

    def test_no_register_execution_for_memory(self):
        result = prepare.transform(self.sources['core_fetch_decode.svh'], 'core_fetch_decode.svh')
        self.assertIn('SYS_MOVCR_FROM: state<=d_mem_write ? S_STORE : S_EXEC;', result)
        core = prepare.transform(self.sources['core.sv'], 'core.sv')
        self.assertIn("st_data = {16'd0, creg0[15:0]};", core)
        self.assertIn('((d_sysop==SYS_MOVCR_FROM) && !d_smsw)', core)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', required=True, type=Path)
    args = parser.parse_args()
    SourceContract.sources = {name: (args.parent/name).read_text() for name in prepare.PARENTS}
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(SourceContract))
    if result.wasSuccessful():
        print(json.dumps({name: hashlib.sha256(prepare.transform(source,name).encode()).hexdigest()
                          for name,source in SourceContract.sources.items()}, indent=2))
    raise SystemExit(not result.wasSuccessful())
