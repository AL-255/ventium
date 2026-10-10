"""Host backport contracts; no RTL/whole-core pass is inferred."""
from pathlib import Path
import unittest

import prepare_current_round_c1 as c1
import prepare_srt_round_floor as floor


class CurrentBackport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        cls.sources = {name: (root/name).read_text() for name in c1.FILES}
        cls.sources[c1.FILES[0]] = floor.transform(cls.sources[c1.FILES[0]])
        cls.sources[c1.CORE] = (root/c1.CORE).read_text()
        cls.patch = (root/'fp_shared/tb/round_c1_integration.patch').read_text()

    def test_exact_patch_and_numeric_hunks(self):
        out = c1.transform(self.sources)
        self.assertEqual(set(out), set(self.sources))
        self.assertIn(floor.NEW, out[c1.FILES[0]])
        self.assertIn('rounded_up <= (oor || pc==2\'b00 || pc==2\'b10)', out[c1.FILES[0]])
        self.assertIn('(up || (resid_neg && !down))', out[c1.FILES[0]])
        self.assertIn('c_status_data[9] = alu_rounded_up;', out[c1.FILES[3]])
        self.assertIn('c_status_data[9] = srt_rounded_up;', out[c1.FILES[3]])

    def test_sentinels_outside_hunks_preserved(self):
        varied = {name: '// keep later performance changes\n'+text for name,text in self.sources.items()}
        out = c1.transform(varied)
        for text in out.values():
            self.assertTrue(text.startswith('// keep later performance changes\n'))

    def test_reverse_all_reviewed_hunks_is_exact(self):
        out = c1.transform(self.sources)
        for name, before, after in reversed(c1.hunks(self.patch)):
            out[name] = c1.once(out[name], after, before)
        out[c1.FILES[0]] = floor.transform(out[c1.FILES[0]])
        for name in c1.FILES:
            self.assertEqual(out[name], self.sources[name], name)

    def test_legacy_port_only(self):
        out = c1.transform(self.sources)
        restored = out[c1.CORE].replace('\n  logic eng_u_rounded_up; // shared-FPU repair; legacy status integration remains separate', '').replace('\n    .rounded_up(eng_u_rounded_up),', '')
        self.assertEqual(restored, self.sources[c1.CORE])

    def test_missing_numeric_repair_refused(self):
        wrong = dict(self.sources)
        wrong[c1.FILES[0]] = wrong[c1.FILES[0]].replace(floor.NEW, floor.OLD)
        with self.assertRaises(ValueError): c1.transform(wrong)

    def test_patch_drift_refused(self):
        with self.assertRaises(ValueError): c1.transform(self.sources, self.patch+'\n')

    def test_partial_or_repeated_merge_refused(self):
        with self.assertRaises(ValueError): c1.transform(c1.transform(self.sources))
        wrong = dict(self.sources)
        wrong[c1.FILES[2]] += '\n// rounded_up partial merge\n'
        with self.assertRaises(ValueError): c1.transform(wrong)

    def test_ambiguous_context_refused(self):
        wrong = dict(self.sources)
        wrong[c1.FILES[3]] += '\n'+self.sources[c1.FILES[3]]
        with self.assertRaises(ValueError): c1.transform(wrong)

    def test_target_set_refused(self):
        for name in self.sources:
            with self.subTest(name=name), self.assertRaises(ValueError):
                c1.transform({n:t for n,t in self.sources.items() if n != name})


if __name__ == '__main__': unittest.main()
