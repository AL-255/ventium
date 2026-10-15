"""Regrade the leaf evidence and reject weakened or unclosed run receipts."""
import copy
import unittest
from pathlib import Path
from unittest.mock import patch

import build_demand_size_core as builder
import run_demand_size_physical as physical

LEAF = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/demand-size-leaf-r1').resolve(strict=True)


class DemandBuild(unittest.TestCase):
    def test_closed_evidence_regrades(self):
        pins = builder.check_leaf(LEAF)
        self.assertIn(str(LEAF/'core.sv'), pins)

    def test_missing_profiles_unwaited_mutants_and_oom_rejected(self):
        original = builder.native.load(LEAF/'closed.json')
        actual_load = builder.native.load
        variants = []
        bad = copy.deepcopy(original); bad['rows'].pop(); variants.append(bad)
        bad = copy.deepcopy(original); bad['rows'][1]['results']['native']['native_exit'] = 0; variants.append(bad)
        bad = copy.deepcopy(original); bad['rows'][0]['results']['native']['actual_wait'] = False; variants.append(bad)
        bad = copy.deepcopy(original); bad['rows'][0]['results']['native']['coverage']['beats'] = 0; variants.append(bad)
        bad = copy.deepcopy(original); bad['memory_events']['oom_kill'] = '1'; variants.append(bad)
        for changed in variants:
            def load(path):
                return changed if path == LEAF/'closed.json' else actual_load(path)
            with self.subTest(changed=changed['rows'][0]['results']['native']), patch.object(builder.native, 'load', load):
                with self.assertRaises(AssertionError):
                    builder.check_leaf(LEAF)

    def test_smm_adapter_only_extends_previously_insufficient_bounds(self):
        import inspect
        changed = physical.adapted_main()
        restored = changed.replace("'8000000'", "'5000000'").replace("'.exit.json'),180)", "'.exit.json'),90)")
        self.assertEqual(restored, inspect.getsource(physical.predecessor.main))
        self.assertIn("assert both['parent']==both['candidate']", changed)
        self.assertIn('grade(name,parsed.records,dump)', changed)


if __name__ == '__main__':
    unittest.main()
