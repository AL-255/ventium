"""Source-release checks; no Vivado, board access or CPU acceptance claim."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_known_good as build


class KnownGood(unittest.TestCase):
    def test_source_closure(self):
        self.assertEqual(build.verify()['reference_bitstream_sha256'][:8], '2886d24c')

    def test_drift_rejected(self):
        data = copy.deepcopy(json.loads(build.MANIFEST.read_text()))
        data['files']['rtl/core/core.sv'] = '0' * 64
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / 'manifest.json'
            manifest.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'source mismatch'):
                build.verify(manifest=manifest)

    def test_path_escape_rejected(self):
        data = copy.deepcopy(json.loads(build.MANIFEST.read_text()))
        data['files'] = {'../escape': '0' * 64}
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / 'manifest.json'
            manifest.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'unsafe manifest'):
                build.verify(manifest=manifest)

    def test_environment_does_not_inherit_experiments(self):
        with patch.dict(build.os.environ, {'VEN_FPGA_FASTPATH':'0', 'VENTIUM_VIVADO_MEMORY_MAX':'1G'}):
            env = build.environment(Path('/repo'), Path('/out'), Path('/vendor'))
        self.assertNotIn('VEN_FPGA_FASTPATH', env)
        self.assertNotIn('VENTIUM_VIVADO_MEMORY_MAX', env)
        self.assertEqual(env['VEN_FPGA_CORE_MHZ'], '40')
        self.assertEqual(env['VENTIUM_VIVADO_MEMORY_POLICY'], 'unbounded')
        self.assertEqual(env['VEN_FPGA_DEFINE_FILE'], '/repo/fpga/known_good_defines.txt')


if __name__ == '__main__':
    unittest.main()
