"""Source-scope checks for the draft, not sequential or timing acceptance."""
import os
from pathlib import Path
import unittest

import prepare_intent_ready_cut as draft


class IntentReadySource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root=Path(os.environ['INTENT_READY_SOURCE']).resolve(strict=True)
        cls.sources={name:(cls.root/name).read_text() for name in draft.PARENTS}

    def test_exact_two_file_delta_and_reverse(self):
        for name,source in self.sources.items():
            changed=draft.transform(source,name)
            self.assertNotEqual(changed,source)
            for old,new,count in reversed(draft.edits(source,name)):
                self.assertEqual(changed.count(new),count)
                changed=changed.replace(new,old)
            self.assertEqual(changed,source)

    def test_parent_drift_and_reapplication_rejected(self):
        for name,source in self.sources.items():
            for bad in (source+'\n',draft.transform(source,name)):
                with self.assertRaises(ValueError):draft.transform(bad,name)

    def test_original_ready_and_assertions_preserved(self):
        source=self.sources['rtl/mem/ven_l1d.sv']
        changed=draft.transform(source,'rtl/mem/ven_l1d.sv')
        old,fast=draft.extract(source)
        self.assertEqual(changed.count(old),1)
        self.assertEqual(changed.count(fast.replace('assign pair_intent_ready =','assign c_pair_intent_ready =')),1)
        for diagnostic in ('PAIR-READY-COFACTOR','PAIR-INTENT: request without prior intent',
                           'PAIR-INTENT: conflicting hint acquired the cache port'):
            self.assertEqual(changed.count(diagnostic),source.count(diagnostic))

    def test_only_caller_consumes_ready_under_offer(self):
        core=(self.root/'rtl/core/core.sv').read_text()
        seam=self.sources['rtl/mem/ventium_l1_axi.sv']
        draft.caller_contract(core,seam)
        with self.assertRaises(AssertionError):draft.caller_contract(core+'\n',seam)
        changed=draft.transform(seam,'rtl/mem/ventium_l1_axi.sv')
        self.assertEqual(changed.count('.c_pair_intent_ready(l1d_store_pair_intent_ready)'),1)
        self.assertIn('core_store_pair_ready_before_intent_cut',changed)


if __name__=='__main__':unittest.main()
