"""Wait-cofactor transfer must preserve sources, defines and acceptance checks."""
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import build_pipe_wait_soc as transfer

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class Transfer(unittest.TestCase):
    def test_exact_shared_delta(self):
        parent = ROOT/'demand-size-soc-r1/source'
        core = ROOT/'pipe-wait-core-r1/candidate'
        shared = sorted(str(p.relative_to(parent)) for p in parent.rglob('*') if p.is_file()
            and p.relative_to(parent).parts[0] in ('rtl', 'fp_shared') and (core/p.relative_to(parent)).is_file())
        self.assertEqual(len(shared), 102)
        self.assertEqual([n for n in shared if transfer.sha(parent/n) != transfer.sha(core/n)], transfer.CHANGES)
        n = transfer.recipe.FILE
        self.assertEqual(transfer.recipe.transform((parent/n).read_text()), (core/n).read_text())

    def test_same_definitions(self):
        command = json.loads((ROOT/'demand-size-soc-r1/build-started.json').read_text())['command']
        actual, definitions = transfer.keep_definitions(command)
        self.assertEqual(actual, command)
        self.assertEqual(len(definitions), 157)
        self.assertTrue({'VEN_X87_MF_STRICT', 'VEN_P54_LOAD_STORE_PAIR', 'VEN_FE_PIPE'} <= set(definitions))
        with self.assertRaises(AssertionError):
            transfer.keep_definitions(command+['+define+VEN_UNREVIEWED'])

    def test_closed_extended_evidence(self):
        pins = transfer.extended_evidence(ROOT, ROOT/'pipe-wait-core-r1')
        self.assertIn(str(ROOT/'pipe-wait-mixed-r1/closed.json'), pins)

    def test_physical_and_matched_gates_still_required(self):
        text = transfer.adapted_prepare()
        compile(text, '<pipe-wait-transfer>', 'exec')
        for name in ('boundary', 'system', 'func', 'delivery', 'physical', 'matched-inputs'):
            self.assertIn('pipe-wait-'+name+'-r1', text)
        self.assertIn('extended_evidence(proof, core)', text)
        self.assertIn('pins.update(extra_pins)', text)

    def test_weakened_mixed_and_held_evidence_rejected(self):
        actual_load = transfer.load
        cases = [('pipe-wait-mixed-r1/closed.json', 'memory_v_retirements', 0),
                 ('pipe-wait-mixed-r1/closed.json', 'wait_held', 0),
                 ('pipe-wait-mixed-r1/closed.json', 'wait_paired', 0),
                 ('pipe-wait-held-r1/result.json', 'cases', [])]
        for relative, field, value in cases:
            path = ROOT/relative
            changed = actual_load(path)
            changed[field] = value
            with patch.object(transfer, 'load', side_effect=lambda p: changed if p == path else actual_load(p)):
                with self.assertRaises(AssertionError):
                    transfer.extended_evidence(ROOT, ROOT/'pipe-wait-core-r1')


if __name__ == '__main__':
    unittest.main()
