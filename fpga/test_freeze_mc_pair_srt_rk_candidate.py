"""Check exact two-file export transforms, without publishing hardware inputs."""
import os
from pathlib import Path
import unittest

import freeze_mc_pair_srt_rk_candidate as export


class SourceContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = Path(os.environ['MC_PAIR_SRT_PARENT'])/'ventium'
        cls.core = (parent/'rtl/core/core.sv').read_text()
        cls.engine = (parent/'rtl/fpu/fpu_srt_div.sv').read_text()

    def test_exact_two_outputs(self):
        payloads = export.expected_payloads(self.core, self.engine)
        self.assertEqual({key: export.sha256(value) for key, value in payloads.items()}, export.CHANGES)

    def test_each_parent_rejects_drift(self):
        for core, engine in ((self.core+'\n', self.engine), (self.core, self.engine+'\n')):
            with self.assertRaises(ValueError):
                export.expected_payloads(core, engine)

    def test_each_reapplication_rejects(self):
        candidate = list(export.expected_payloads(self.core, self.engine).values())
        for core, engine in ((candidate[0].decode(), self.engine), (self.core, candidate[1].decode())):
            with self.assertRaises(ValueError):
                export.expected_payloads(core, engine)


if __name__ == '__main__':
    unittest.main()
