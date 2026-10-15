"""Exact one-source PC transfer and unchanged resource/mode requirements."""
from pathlib import Path
import unittest

import build_fetch_fragment_soc as build
import freeze_fetch_fragment_rk_candidate as freeze


class Checks(unittest.TestCase):
    def test_frozen_projection_rejects_other_changes(self):
        root = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X')
        name = 'ventium/'+build.recipe.FILE
        old = (root/'prefix-payload-fpga-r1'/name).read_bytes()
        new = (root/'fetch-fragment-core-r1/candidate'/build.recipe.FILE).read_bytes()
        self.assertEqual(freeze.CHANGES, [name])
        self.assertTrue(freeze.check_delta(name, old, new))
        for left, right in ((old, old), (old, new+b'\n'), (old+b'\n', new)):
            with self.assertRaises(Exception): freeze.check_delta(name, left, right)
        self.assertFalse(freeze.check_delta('ventium/rtl/other.sv', b'a', b'a'))
        with self.assertRaises(Exception):
            freeze.check_delta('ventium/rtl/other.sv', b'a', b'b')

    def test_source_delta_is_exact(self):
        root = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X')
        old = (root/'prefix-payload-soc-r1/source'/build.recipe.FILE).read_text()
        new = (root/'fetch-fragment-core-r1/candidate'/build.recipe.FILE).read_text()
        self.assertEqual(build.transform(build.recipe.FILE, old), new)
        with self.assertRaises(ValueError): build.transform('rtl/other.sv', old)
        with self.assertRaises(ValueError): build.transform(build.recipe.FILE, old+'\n')

    def test_profile_and_resource_guards(self):
        _, text = build.derive()
        for line in (
            'assert len(shared) == 102',
            "assert [n for n in shared if sha(source / n) != sha(core / 'candidate' / n)] == CHANGES",
            'assert len(defs) == len(set(defs)) == 156',
            "assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command",
            "assert (audit['canonical_functional_passes'], audit['canonical_functional_failures']) == (7, 101)",
            "assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]",
            "assert command[affinity+1:affinity+3] == ['-c', '0-9,12-31']",
            "assert shutil.disk_usage(scratch).free > 5 * 1024**3",
            "tooling_deltas = tooling.qualify_tooling(pins)"):
            self.assertIn(line, text)


if __name__ == '__main__': unittest.main()
