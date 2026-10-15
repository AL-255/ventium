import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import freeze_decode_bus_rk_candidate as freeze

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
PARENT = ROOT/'branch-address-fpga-r1'
REPO = Path(__file__).resolve().parents[1]


class Freeze(unittest.TestCase):
    def test_only_reviewed_payload(self):
        name = 'ventium/'+freeze.native.recipe.FILE
        old = (PARENT/name).read_bytes()
        new = (ROOT/'decode-bus-core-r1/candidate'/freeze.native.recipe.FILE).read_bytes()
        self.assertTrue(freeze.check_delta(name, old, new))
        self.assertFalse(freeze.check_delta('unchanged', b'same', b'same'))
        for target, before, after in ((name, old, old), (name, old, new+b'\n'), ('unreviewed', b'a', b'b')):
            with self.assertRaises(Exception): freeze.check_delta(target, before, after)

    def test_native_source_contract_and_profile_mutants(self):
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertEqual(Path(os.environ['TMPDIR']).resolve(), scratch)
        old = (PARENT/'defines.txt').read_text().splitlines()
        strict = old[:155]+[freeze.native.FLAG]+old[155:]
        variants = [strict, old, strict[:155]+['VEN_WRONG_STRICT_FLAG']+strict[156:]]
        with tempfile.TemporaryDirectory(prefix='decode-bus-tcl-test-', dir=scratch) as folder:
            profile = Path(folder)/'defines.txt'
            for index, defs in enumerate(variants):
                profile.write_text('\n'.join(defs)+'\n')
                p = subprocess.run(['tclsh', REPO/'fpga/test_strict_mf_rk_wrapper.tcl',
                    PARENT/'ventium/fpga/create_project_3mhz_wrapper.tcl', PARENT/'flow', profile,
                    PARENT/'ventium', PARENT/'template', 'logic_only'], capture_output=True, text=True, timeout=15)
                if index == 0:
                    self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
                    self.assertIn('exact159defs', p.stdout)
                else:
                    self.assertNotEqual(p.returncode, 0)
                    self.assertIn('wrong strict waiting-x87', p.stderr)


if __name__ == '__main__':
    unittest.main()
