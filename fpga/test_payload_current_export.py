"""Exact hardware-profile and Tcl-expansion checks; no Vivado is invoked."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import freeze_payload_current_rk_candidate as freeze


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(os.environ['PAYLOAD_CURRENT_FPGA_PARENT']).resolve(strict=True)
        cls.hardware = json.loads((cls.parent/'input-manifest.json').read_text())['hardware_defines']
        cls.native = sorted((set(cls.hardware)-{'SYNTHESIS', 'VTM_NO_DPI'}) | {freeze.recipe.payload.FLAG})

    def test_only_one_ordered_extension(self):
        actual = freeze.hardware_profile(self.hardware, self.native)
        self.assertEqual(actual[:153], self.hardware[:153])
        self.assertEqual(actual[153], freeze.recipe.payload.FLAG)
        self.assertEqual(actual[154:], self.hardware[153:])

    def test_profile_rejects_mode_loss_extra_and_missing_hint(self):
        for native in (self.native+[self.native[0]],
                       [n for n in self.native if n != freeze.recipe.payload.FLAG],
                       [n if n != 'VEN_P54_DUAL_LOAD_PAIR' else 'UNRELATED' for n in self.native]):
            with self.assertRaises(freeze.base.FreezeError):
                freeze.hardware_profile(self.hardware, native)

    def test_exact_157_define_tcl_expansion(self):
        with tempfile.TemporaryDirectory(prefix='payload-export-test.', dir=os.environ['TMPDIR']) as temp:
            root = Path(temp).resolve(strict=True)
            shutil.copytree(self.parent/'flow', root/'flow')
            definitions = root/'defines.txt'
            definitions.write_text('\n'.join(freeze.hardware_profile(self.hardware, self.native))+'\n')
            command = ['tclsh', str(freeze.REPO/'fpga/test_payload_current_rk_wrapper.tcl'),
                       str(self.parent/'ventium/fpga/create_project_3mhz_wrapper.tcl'),
                       str(root/'flow'), str(definitions), str(self.parent/'ventium'),
                       str(self.parent/'template'), 'logic_only']
            result = subprocess.run(command, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertIn('exact157defs', result.stdout)
            definitions.write_text(definitions.read_text().replace(freeze.recipe.payload.FLAG, 'WRONG_FLAG'))
            wrong = subprocess.run(command, capture_output=True, text=True, timeout=15)
            self.assertNotEqual(wrong.returncode, 0)
            self.assertIn('wrong payload-kind extension/order', wrong.stderr)


if __name__ == '__main__':
    unittest.main()
