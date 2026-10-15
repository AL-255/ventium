"""Check the frozen three-file transfer; never invoke Vivado or deploy."""
import hashlib
import json
from pathlib import Path
import unittest

import freeze_pair_next_disjoint_rk_candidate as freeze

ROOT=Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X')


class Transfer(unittest.TestCase):
    def test_frozen_profile_and_three_exact_deltas(self):
        parent=ROOT/'prefix-payload-fpga-r1'
        candidate=ROOT/'pair-next-disjoint-fpga-r1'
        old=json.loads((parent/'input-manifest.json').read_text())
        new=json.loads((candidate/'input-manifest.json').read_text())
        self.assertEqual(new['hardware_defines'],old['hardware_defines'])
        self.assertEqual(len(new['hardware_defines']),158)
        self.assertEqual(new['core_mhz'],40)
        self.assertEqual(new['source_closure'],dict(filelist_units=117,include_edges=49))
        self.assertEqual(new['qualification'],'UNQUALIFIED')
        changes=[]
        for row in new['files']:
            name=row['frozen']; before=(parent/name).read_bytes(); after=(candidate/name).read_bytes()
            self.assertEqual(hashlib.sha256(after).hexdigest(),row['sha256'])
            if freeze.check_delta(name,before,after):changes.append(name)
        self.assertEqual(sorted(changes),freeze.CHANGES)

    def test_missing_and_extra_edits_fail_closed(self):
        parent=ROOT/'prefix-payload-fpga-r1'
        name=freeze.CHANGES[0]; before=(parent/name).read_bytes()
        with self.assertRaises(Exception):freeze.check_delta(name,before,before)
        with self.assertRaises(Exception):freeze.check_delta('ventium/rtl/unreviewed.sv',b'a',b'b')
        with self.assertRaises(Exception):freeze.check_delta(name,before,before+b'\n')


if __name__=='__main__':unittest.main()
