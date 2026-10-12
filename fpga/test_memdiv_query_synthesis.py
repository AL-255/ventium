"""Protect the exact-parent selector experiment and unchanged safety limits."""
import unittest
import prepare_memdiv_query_synthesis as recipe


class PreparationTests(unittest.TestCase):
    def originals(self):
        result = {}
        for name, digest in recipe.TEMPLATES.items():
            p = recipe.ROOT/name
            self.assertEqual(recipe.sha(p), digest)
            result[name] = p.read_text()
        return result

    def test_guard_profile_and_evidence_preserved(self):
        before = self.originals(); after = recipe.derive(before)
        for phase in ('synthesis', 'clock'):
            text = after['memdiv-query-'+phase+'-r1/run.py']
            recipe.guarded(text, before['memdiv-'+phase+'-r1/run.py'])
            self.assertIn("len(manifest['hardware_defines']) == 158", text)
        synth = after['memdiv-query-synthesis-r1/run.py']
        for text in ('shutil.disk_usage(root).free > 6*gib',
                     'shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth',
                     "assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']",
                     "core['changes']==changes", "prepared['changes']==changes",
                     "changes=['rtl/core/core_mem_chain.svh']", "prepared['added_defines']==[]",
                     "'memdiv-query-soc-r1/coremark'", '[4767218,4753406]',
                     "'memdiv-query-core-r1/verify-closed.json'"):
            self.assertIn(text, synth)
        clock = after['memdiv-query-clock-r1/run.py']
        self.assertIn(str(recipe.ROOT/'memdiv-synthesis-r1'), clock)
        self.assertIn(recipe.PARENT_DCP, clock)
        self.assertIn('(-9.391)', after['memdiv-query-clock-r1/audit_closed.py'])
        self.assertEqual(after['memdiv-query-clock-r1/audit.tcl'], before['memdiv-clock-r1/audit.tcl'])

    def test_unreviewed_delta_rejected(self):
        before = self.originals()
        before['memdiv-synthesis-r1/run.py'] = before['memdiv-synthesis-r1/run.py'].replace(
            "changes=['fp_shared/ven_fp_top.sv','rtl/fpu/fpu_srt_div.sv']",
            "changes=['rtl/core/core.sv']")
        with self.assertRaises(AssertionError): recipe.derive(before)


if __name__ == '__main__': unittest.main()
