"""Source-transfer and strict-profile tests; not full-PC acceptance."""
import json
from pathlib import Path
import unittest
import build_decode_bus_soc as transfer

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class Transfer(unittest.TestCase):
    def test_exact_shared_closure(self):
        parent, core = ROOT/'branch-address-soc-r1/source', ROOT/'decode-bus-core-r1/candidate'
        shared = sorted(str(p.relative_to(parent)) for p in parent.rglob('*') if p.is_file()
            and p.relative_to(parent).parts[0] in ('rtl', 'fp_shared') and (core/p.relative_to(parent)).is_file())
        self.assertEqual(len(shared), 102)
        self.assertEqual([n for n in shared if transfer.sha(parent/n) != transfer.sha(core/n)], transfer.CHANGES)
        n = transfer.recipe.FILE
        self.assertEqual(transfer.recipe.transform((parent/n).read_text()), (core/n).read_text())
        with self.assertRaises(ValueError): transfer.recipe.transform((core/n).read_text())

    def test_exact_define_addition(self):
        command = json.loads((ROOT/'branch-address-soc-r1/build-started.json').read_text())['command']
        changed, defs = transfer.add_strict(command)
        self.assertEqual(len(defs), 157)
        self.assertEqual(defs.count(transfer.FLAG), 1)
        self.assertEqual([s for s in changed if s != '+define+'+transfer.FLAG], command)
        with self.assertRaises(AssertionError): transfer.add_strict(changed)


if __name__ == '__main__':
    unittest.main()
