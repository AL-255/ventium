"""Protect immediate-read experiment scope and unchanged resource safeguards."""
import unittest
import prepare_pair_now_read_synthesis as recipe


class PreparationTests(unittest.TestCase):
    def originals(self):
        result={}
        for name,digest in recipe.TEMPLATES.items():
            p=recipe.ROOT/name
            self.assertEqual(recipe.sha(p),digest)
            result[name]=p.read_text()
        return result

    def test_scope_guards_and_parent(self):
        before=self.originals(); after=recipe.derive(before)
        for phase in ('synthesis','clock'):
            text=after['pair-now-read-'+phase+'-r1/run.py']
            recipe.guarded(text,before['memdiv-query-'+phase+'-r1/run.py'])
            self.assertIn("len(manifest['hardware_defines']) == 158",text)
        synth=after['pair-now-read-synthesis-r1/run.py']
        for term in ('shutil.disk_usage(root).free > 6*gib',
                     'shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth',
                     "changes=['rtl/core/core.sv']", "core['changes']==changes",
                     "prepared['changes']==changes", "prepared['added_defines']==[]",
                     "assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']",
                     "'pair-now-read-soc-r1/coremark'", '[4767218,4753406]'):
            self.assertIn(term,synth)
        clock=after['pair-now-read-clock-r1/run.py']
        self.assertIn(str(recipe.ROOT/'memdiv-query-synthesis-r1'),clock)
        self.assertIn(recipe.PARENT_DCP,clock)
        self.assertIn('(-7.598)',after['pair-now-read-clock-r1/audit_closed.py'])
        self.assertEqual(after['pair-now-read-clock-r1/audit.tcl'],before['memdiv-query-clock-r1/audit.tcl'])

    def test_source_delta_drift_rejected(self):
        before=self.originals()
        name='memdiv-query-synthesis-r1/run.py'
        before[name]=before[name].replace("changes=['rtl/core/core_mem_chain.svh']",
                                          "changes=['rtl/mem/ven_l1d.sv']")
        with self.assertRaises(AssertionError): recipe.derive(before)


if __name__=='__main__': unittest.main()
