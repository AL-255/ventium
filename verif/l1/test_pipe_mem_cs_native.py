"""Regrade native CS-extent evidence, including negative checker controls."""
import copy
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from prepare_pipe_mem_cs_fixtures import sha
from run_pipe_mem_cs_fixtures import grade_native, tracefmt


class NativeCSFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(os.environ['PIPE_CS_NATIVE']).resolve(strict=True)
        fixtures = Path(os.environ['PIPE_CS_FIXTURES']).resolve(strict=True)
        cls.layouts = json.loads((fixtures/'closed.json').read_text())['cases']
        pins = json.loads((cls.root/'started.json').read_text())['pins']
        assert all(sha(p) == h for p, h in pins.items())

    def test_all_native_runs_and_complete_ab_equality(self):
        runs = 0
        for layout in self.layouts:
            w = layout['expected']
            leaf = self.root/f"k{w['kind']}-n{w['length']}-over{w['over']}"
            for latency in (0, 7):
                for mode in ('cycle-func', 'cycle'):
                    results = []
                    for name in ('control', 'candidate'):
                        stem = f'{name}-l{latency}-{mode}'
                        self.assertEqual((leaf/(stem+'.exit')).read_text().strip(), '133')
                        trace, measurement = grade_native(leaf, stem, layout)
                        results.append((trace.records, measurement))
                        runs += 1
                    self.assertEqual(*results)
        self.assertEqual(runs, 96)

    def fixture(self, mode='cycle-func'):
        return self.root/'k0-n2-over0', 'candidate-l0-'+mode, self.layouts[0]

    def test_changed_precise_fault_pc_is_rejected(self):
        leaf, stem, layout = self.fixture()
        original = Path.read_text
        def changed(path, *args, **kwargs):
            text = original(path, *args, **kwargs)
            if path.suffix in ('.stdout', '.stderr'):
                text = text.replace('vec=13 err=00000000 pc=00008032',
                                    'vec=13 err=00000000 pc=00008030')
            return text
        with patch.object(Path, 'read_text', changed):
            with self.assertRaises(AssertionError):
                grade_native(leaf, stem, layout)

    def test_lost_v_retirement_is_rejected(self):
        leaf, stem, layout = self.fixture('cycle')
        trace = copy.deepcopy(tracefmt.read_trace(str(leaf/(stem+'.vtrace'))))
        for row in trace.records:
            row['pipe'] = 'U'
            row['paired'] = False
        with patch.object(tracefmt, 'read_trace', return_value=trace):
            with self.assertRaisesRegex(AssertionError, 'UV warmup did not pair'):
                grade_native(leaf, stem, layout)

    def test_load_destination_corruption_is_rejected(self):
        leaf, stem, layout = self.fixture()
        trace = copy.deepcopy(tracefmt.read_trace(str(leaf/(stem+'.vtrace'))))
        for row in trace.records:
            if int(row['pc'], 0) == layout['symbols']['case_return']:
                row['eax'] = '0xdeadcafe'
        with patch.object(tracefmt, 'read_trace', return_value=trace):
            with self.assertRaises(AssertionError):
                grade_native(leaf, stem, layout)


if __name__ == '__main__':
    unittest.main()
