import unittest

import prepare_fetch_fragment_synthesis as recipe


class Checks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        for name, digest in recipe.TEMPLATES.items():
            path = recipe.ROOT/name
            assert recipe.sha(path) == digest
            cls.original[name] = path.read_text()
        cls.outputs = recipe.derive(cls.original)

    def test_resource_guards_unchanged(self):
        for phase, guard in (('synthesis', recipe.guarded), ('clock', recipe.clock_guarded)):
            new = self.outputs[f'fetch-fragment-{phase}-r1/run.py']
            old = self.original[f'prefix-payload-{phase}-r1/run.py']
            guard(new, old)
            with self.assertRaises(AssertionError):
                guard(new.replace('if free < 4*gib:', 'if free < 1*gib:'), old)
        new = self.outputs['fetch-fragment-synthesis-r1/run.py']
        old = self.original['prefix-payload-synthesis-r1/run.py']
        first, last = 'host = available()\n', "(root/'once').mkdir()"
        self.assertEqual(new[new.index(first):new.index(last)], old[old.index(first):old.index(last)])

    def test_correct_proofs_and_failed_gates_retained(self):
        new = self.outputs['fetch-fragment-synthesis-r1/run.py']
        for line in (
            "leaf=load_proof('fetch-fragment-leaf-r5/closed.json')",
            "checks=8529920,mutants_failed=2", "['unsat','sat','sat','sat']",
            "func['functional_records']==80800",
            "assert fetch['passed'] and fetch['cases']==22 and fetch['qemu_comparisons']==88",
            "fault=load_proof('fetch-fragment-env-fault-r1/closed.json')",
            "tooling_deltas=native.tooling.qualify_tooling(pins)",
            "fetch-fragment-soc-r1/coremark-r2", "assert not boundary['passed'] and boundary['errors']",
            'baseline_gameplay_ipc=0.50520554,baseline_window=[5600065237,5700065237]'):
            self.assertIn(line, new)
        self.assertEqual(self.outputs['fetch-fragment-clock-r1/audit.tcl'],
                         self.original['prefix-payload-clock-r1/audit.tcl'])


if __name__ == '__main__': unittest.main()
