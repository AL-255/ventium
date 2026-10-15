"""No extra RTL delta, lost strict-MF flag or changed full-PC command."""
import json
from pathlib import Path
import unittest

import build_early_bus_soc as transfer

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class Transfer(unittest.TestCase):
    def test_shared_source_closure(self):
        parent,core=ROOT/'decode-bus-soc-r1/source',ROOT/'early-bus-core-r1/candidate'
        shared=sorted(str(p.relative_to(parent)) for p in parent.rglob('*') if p.is_file()
            and p.relative_to(parent).parts[0] in ('rtl','fp_shared') and (core/p.relative_to(parent)).is_file())
        self.assertEqual(len(shared),102)
        self.assertEqual([n for n in shared if transfer.sha(parent/n)!=transfer.sha(core/n)],transfer.CHANGES)
        n=transfer.recipe.FILE
        self.assertEqual(transfer.recipe.transform((parent/n).read_text()),(core/n).read_text())

    def test_definitions_unchanged(self):
        command=json.loads((ROOT/'decode-bus-soc-r1/build-started.json').read_text())['command']
        actual,defs=transfer.keep_definitions(command)
        self.assertEqual(actual,command)
        self.assertEqual(len(defs),157)
        self.assertIn('VEN_X87_MF_STRICT',defs)
        for bad in ([s for s in command if s!='+define+VEN_X87_MF_STRICT'],
                    command+['+define+VEN_UNREVIEWED']):
            with self.assertRaises(AssertionError): transfer.keep_definitions(bad)


if __name__=='__main__': unittest.main()
