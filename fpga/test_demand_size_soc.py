"""Demand-width transfer scope and unchanged acceptance-policy checks."""
import inspect
import json
from pathlib import Path
import unittest

import build_demand_size_soc as transfer

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class Transfer(unittest.TestCase):
    def test_exact_shared_source_delta(self):
        parent, core = ROOT/'early-bus-soc-r1/source', ROOT/'demand-size-core-r1/candidate'
        shared = sorted(str(p.relative_to(parent)) for p in parent.rglob('*') if p.is_file()
            and p.relative_to(parent).parts[0] in ('rtl', 'fp_shared') and (core/p.relative_to(parent)).is_file())
        self.assertEqual(len(shared), 102)
        self.assertEqual([n for n in shared if transfer.sha(parent/n) != transfer.sha(core/n)], transfer.CHANGES)
        n = transfer.recipe.FILE
        self.assertEqual(transfer.recipe.transform((parent/n).read_text()), (core/n).read_text())

    def test_definitions_unchanged(self):
        command = json.loads((ROOT/'early-bus-soc-r1/build-started.json').read_text())['command']
        actual, definitions = transfer.keep_definitions(command)
        self.assertEqual(actual, command)
        self.assertEqual(len(definitions), 157)
        self.assertIn('VEN_X87_MF_STRICT', definitions)
        self.assertIn('VEN_SFETCH16_DEMAND', definitions)
        for bad in ([s for s in command if s != '+define+VEN_X87_MF_STRICT'],
                    command+['+define+VEN_UNREVIEWED']):
            with self.assertRaises(AssertionError):
                transfer.keep_definitions(bad)

    def test_proof_contract_not_relaxed(self):
        new = transfer.adapted_prepare()
        recovered = new.replace('demand-size-', 'early-bus-').replace('sim_demand_size_', 'sim_early_bus_')
        # The left sides of the predecessor adapter's replacements remain its
        # original decode-bus r1 inputs; restore only the new early-bus targets.
        recovered = recovered.replace('early-bus-func-r1', 'early-bus-func-r2')
        recovered = recovered.replace('early-bus-delivery-r1', 'early-bus-delivery-r2')
        recovered = recovered.replace('early-bus-physical-r1', 'early-bus-physical-r2')
        recovered = recovered.replace('(\"name.endswith(\'delivery-r1\')\",\"name.endswith(\'delivery-r1\')\")',
                                      '(\"name.endswith(\'delivery-r1\')\",\"name.endswith(\'delivery-r2\')\")')
        recovered = recovered.replace('(\"name.endswith(\'func-r1\')\",\"name.endswith(\'func-r1\')\")',
                                      '(\"name.endswith(\'func-r1\')\",\"name.endswith(\'func-r2\')\")')
        recovered = recovered.replace('request-independent demand width; original issued-size and inactive-authority assertions',
                                      'early linear payload default; original bus driver assertions')
        recovered = recovered.replace("Path(predecessor.__file__),Path(__file__).with_name('build_early_bus_soc.py'),",
                                      'Path(predecessor.__file__),')
        self.assertEqual(recovered, inspect.getsource(transfer.previous.prepare))


if __name__ == '__main__':
    unittest.main()
