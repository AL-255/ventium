import ast
from pathlib import Path
import unittest
import run_response_payload_core as r


class CorpusAdapterTests(unittest.TestCase):
    def test_fp_changes_only_feature_identity_and_fixture_location(self):
        source = (r.REPO/'verif/issue_uv/run-fp-high-payload-ab.py').read_text()
        changed = r.adapt(source,'fp')
        ast.parse(changed)
        restored = changed.replace("HERE = Path("+repr(str(r.REPO/'verif/issue_uv'))+")",
                                   "HERE = Path(__file__).resolve().parent")
        restored = restored.replace("added = {'"+r.FLAG+"'}", "added = {'VEN_FP_LOAD64_PAYLOAD_SELECT'}")
        self.assertEqual(restored,source)

    def test_integer_requires_full_cycle_identity_not_speedup(self):
        source = (r.HERE/'run_store_warm_core.py').read_text()
        changed = r.adapt(source,'integer')
        ast.parse(changed)
        self.assertIn("assert cycle_records[latency, 'control'] == cycle_records[latency, 'candidate']",changed)
        self.assertIn("assert all(r['saved_clocks']==0 for r in deltas)",changed)
        self.assertEqual(changed.count('compare.compare_func('),source.count('compare.compare_func('))
        self.assertEqual(changed.count('native.grade_native('),source.count('native.grade_native('))
        self.assertIn("assert len(pairs) == 1",changed)
        self.assertIn("--l1-axi",changed)

    def test_ambiguous_or_stale_driver_fails_closed(self):
        source = (r.REPO/'verif/issue_uv/run-fp-high-payload-ab.py').read_text()
        anchor = "added = {'VEN_FP_LOAD64_PAYLOAD_SELECT'}"
        for bad in (source.replace(anchor,''),source+'\n'+anchor):
            with self.assertRaises(ValueError): r.adapt(bad,'fp')

    def test_unknown_corpus_rejected(self):
        with self.assertRaises(ValueError): r.adapt('', 'guest-hack')


if __name__=='__main__':
    unittest.main()
