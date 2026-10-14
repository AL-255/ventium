"""The complete-cache adapter must only add passive observations."""
import difflib
from pathlib import Path
import unittest

from run_parallel_next_cache import bench,FIXTURE,sha


class Fixture(unittest.TestCase):
    def test_only_insertions(self):
        path=Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X/window-current-cache-r1/tb_l1d_mem_chain.sv')
        self.assertEqual(sha(path),FIXTURE)
        original=path.read_text(); changed=bench(original)
        edits=[v for v in difflib.SequenceMatcher(None,original.splitlines(),changed.splitlines(),
                    autojunk=False).get_opcodes() if v[0]!='equal']
        self.assertEqual([v[0] for v in edits],['insert','insert'])
        self.assertIn('dut.hit_n0 !== control.hit_n0',changed)
        self.assertIn('next_crossline_samples += dut.xline',changed)
        self.assertEqual(original.count('dut.'),changed.count('dut.')-8)


if __name__ == '__main__': unittest.main()
