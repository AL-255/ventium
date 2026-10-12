"""Exact-source composition tests, not native whole-core acceptance."""
import os
from pathlib import Path
import unittest

import prepare_payload_current as recipe
import run_payload_code_hint_leaf as mux
import run_payload_fetch_kind_leaf as requests
import run_payload_current_canonical as replay
import build_payload_current_core as builder


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(os.environ['PAYLOAD_CURRENT_PARENT'])
        cls.old = Path(os.environ['PAYLOAD_CODE_HINT_PARENT'])
        cls.current = {n: (cls.parent/n).read_text() for n in recipe.CURRENT}
        cls.original = {n: (cls.old/n).read_text() for n in recipe.CURRENT}
        cls.result = recipe.transform(cls.current, cls.original)

    def test_all_current_changes_survive_disabled_hint(self):
        for name, source in self.result.items():
            expected = self.current[name]
            if name == 'rtl/mem/ven_l1d.sv':
                expected = recipe.overlap.transform(expected)
            self.assertEqual(recipe.payload.select_hint_branch(source, False).split(), expected.split())

    def test_extracted_payload_proof_is_unchanged(self):
        original_hint = recipe.payload.transform(self.original)
        for on in (False, True):
            self.assertEqual(mux.leaf(self.result['rtl/mem/ven_l1d.sv'], 'check', on),
                             mux.leaf(original_hint['rtl/mem/ven_l1d.sv'], 'check', on))

    def test_extracted_request_proof_is_unchanged(self):
        self.assertEqual(requests.extract(self.original['rtl/core/core.sv'],
                                         (self.old/'rtl/core/core_bus_driver.svh').read_text()),
                         requests.extract(self.result['rtl/core/core.sv'],
                                          (self.parent/'rtl/core/core_bus_driver.svh').read_text()))
        self.assertEqual(self.result['rtl/core/core.sv'].count(recipe.fetch.NEW), 1)

    def test_drift_and_reapplication_rejected(self):
        for name in recipe.CURRENT:
            changed = dict(self.current)
            changed[name] += '\n'
            with self.assertRaises(ValueError):
                recipe.transform(changed, self.original)
        with self.assertRaises(ValueError):
            recipe.transform(self.result, self.original)

    def test_lift_refuses_ambiguous_or_changed_context(self):
        before = 'a\nb\nc\nd\ne\nf\n'
        after = before.replace('c\n', 'changed\n')
        for source in (before+before, before.replace('b\n', 'drift\n')):
            with self.assertRaises(ValueError):
                recipe.lift(source, before, after)

    def test_replay_changes_only_the_exact_profile_guard(self):
        source = Path(replay.original.__file__).read_text()
        changed = replay.adapt(source)
        guard = ('    assert len(profiles[0]) == 150 and '+repr(replay.FLAG)+' not in profiles[0]\n'
                 '    assert profiles[1] == profiles[0] | {'+repr(replay.FLAG)+'}')
        self.assertEqual(changed.replace(guard, '    assert profiles[0]==profiles[1] and len(profiles[0])==150'), source)
        control = {'D'+str(i) for i in range(150)}
        checks = '\n'.join(line.strip() for line in guard.splitlines())
        exec(checks, {'profiles': [control, control | {replay.FLAG}]})
        for candidate in (control, control | {replay.FLAG, 'UNRELATED'}, (control-{'D0'}) | {replay.FLAG}):
            with self.assertRaises(AssertionError):
                exec(checks, {'profiles': [control, candidate]})

    def test_overlap_admission_requires_both_native_positives_and_mutant_failure(self):
        def result():
            return dict(passed=True, pins_unchanged=True, errors=[], rows=[
                dict(label=name, build_exit=0, native_exit=int(mutant), mutant=mutant)
                for name,mutant in [('ff-primary', False), ('lut-primary-shadow', False),
                                    ('wrong-unowned-overlap', True)]])
        builder.check_overlap(result())
        for i in range(3):
            bad = result()
            bad['rows'][i]['native_exit'] ^= 1
            with self.assertRaises(AssertionError): builder.check_overlap(bad)
        bad = result()
        bad['rows'].pop()
        with self.assertRaises(AssertionError): builder.check_overlap(bad)


if __name__ == '__main__':
    unittest.main()
