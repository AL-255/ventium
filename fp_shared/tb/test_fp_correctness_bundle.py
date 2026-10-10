"""Composition and failure-atomicity tests, not RTL execution or ISA proof."""
from pathlib import Path
import unittest

import prepare_fp_correctness_bundle as bundle


class BundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        repo = Path(__file__).resolve().parents[2]
        cls.sources = {name: (repo/name).read_text() for name in bundle.FILES}
        name = bundle.arithmetic.FILES[0]
        cls.sources[name] = bundle.arithmetic.floor.transform(cls.sources[name])

    def test_exact_reviewed_composition(self):
        want = dict(self.sources)
        want.update(bundle.arithmetic.transform({name: want[name]
            for name in (*bundle.arithmetic.FILES, bundle.arithmetic.CORE)}))
        for stage in (bundle.register, bundle.memory):
            for name, fn in stage.TRANSFORMS.items():
                want[name] = fn(want[name])
        self.assertEqual(bundle.transform(self.sources), want)
        self.assertEqual(len(want), 7)

    def test_no_input_mutation(self):
        original = dict(self.sources)
        bundle.transform(self.sources)
        self.assertEqual(self.sources, original)

    def test_stage_failure_does_not_publish_partial_changes(self):
        sources = dict(self.sources)
        sources['fp_shared/ven_fp_misc.sv'] = '// missing last-stage owner\n'
        original = dict(sources)
        with self.assertRaises(ValueError):
            bundle.transform(sources)
        self.assertEqual(sources, original)

    def test_unrelated_performance_text_preserved(self):
        sources = {name: '// later performance prefix\n'+text+'\n// later performance tail\n'
                   for name, text in self.sources.items()}
        for text in bundle.transform(sources).values():
            self.assertTrue(text.startswith('// later performance prefix\n'))
            self.assertTrue(text.endswith('// later performance tail\n'))

    def test_repeated_partial_or_wrong_file_set_refused(self):
        with self.assertRaises(ValueError):
            bundle.transform(bundle.transform(self.sources))
        for name in bundle.FILES:
            with self.subTest(name=name), self.assertRaises(ValueError):
                bundle.transform({n: t for n, t in self.sources.items() if n != name})
        for stage in (bundle.register, bundle.memory):
            for name, fn in stage.TRANSFORMS.items():
                wrong = dict(self.sources); wrong[name] = fn(wrong[name])
                with self.subTest(name=name), self.assertRaises(ValueError):
                    bundle.transform(wrong)

    def test_numerical_payload_and_owner_sidebands_retained(self):
        out = bundle.transform(self.sources)
        self.assertIn(bundle.arithmetic.floor.NEW, out['rtl/fpu/fpu_srt_div.sv'])
        top = out['fp_shared/ven_fp_top.sv']
        for owner in ('alu', 'srt', 'misc'):
            self.assertEqual(top.count('c_status_data[9] = '+owner+'_rounded_up;'), 1)
        for bits, width in ((32, 35), (64, 67)):
            package = out['rtl/fpu/fpu_x87_pkg.sv']
            self.assertIn(f'logic [{width-1}:0] fx_to_f{bits}_ex(', package)
            self.assertIn(f'return result_with_c1[{width-1}:0]', package)
        for op in ('frac + 24\'d1', 'frac + 53\'d1', 'fx_dir_up('):
            self.assertEqual(out['rtl/fpu/fpu_x87_pkg.sv'].count(op),
                             self.sources['rtl/fpu/fpu_x87_pkg.sv'].count(op))


if __name__ == '__main__':
    unittest.main()
