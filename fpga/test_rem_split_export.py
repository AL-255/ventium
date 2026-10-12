"""Check exact hardware mode preservation and real Tcl source expansion."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import freeze_rem_split_rk_candidate as freeze


class ExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path('/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS/payload-current-fpga-r1').resolve(strict=True)
        cls.defs = json.loads((cls.parent/'input-manifest.json').read_text())['hardware_defines']
        cls.native = sorted((set(cls.defs)-{'SYNTHESIS','VTM_NO_DPI'})|{freeze.FLAG})

    def test_exact_extension(self):
        actual = freeze.hardware_profile(self.defs,self.native)
        self.assertEqual(len(actual),158)
        self.assertEqual([d for d in actual if d != freeze.FLAG],self.defs)
        self.assertEqual(actual[154],freeze.FLAG)

    def test_profile_drift_rejected(self):
        for defs in (self.native+[self.native[0]], [d for d in self.native if d != freeze.FLAG],
                     [d if d != 'VEN_P54_DUAL_LOAD_PAIR' else 'WRONG' for d in self.native]):
            with self.assertRaises(freeze.parent_flow.base.FreezeError): freeze.hardware_profile(self.defs,defs)

    def test_tcl_expansion_and_wrong_flag(self):
        with tempfile.TemporaryDirectory(prefix='rem-split-export-test.',dir=os.environ['TMPDIR']) as tmp:
            root = Path(tmp).resolve(strict=True); shutil.copytree(self.parent/'flow',root/'flow')
            defs = root/'defines.txt'; defs.write_text('\n'.join(freeze.hardware_profile(self.defs,self.native))+'\n')
            cmd = ['tclsh',str(freeze.REPO/'fpga/test_rem_split_rk_wrapper.tcl'),
                str(self.parent/'ventium/fpga/create_project_3mhz_wrapper.tcl'),str(root/'flow'),str(defs),
                str(self.parent/'ventium'),str(self.parent/'template'),'logic_only']
            ok = subprocess.run(cmd,capture_output=True,text=True,timeout=15)
            self.assertEqual(ok.returncode,0,ok.stdout+ok.stderr)
            self.assertIn('exact158defs',ok.stdout)
            defs.write_text(defs.read_text().replace(freeze.FLAG,'WRONG'))
            bad = subprocess.run(cmd,capture_output=True,text=True,timeout=15)
            self.assertNotEqual(bad.returncode,0)
            self.assertIn('wrong remainder operand extension/order',bad.stderr)


if __name__ == '__main__': unittest.main()
