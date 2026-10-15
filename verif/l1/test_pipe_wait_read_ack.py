"""Exact-source and coverage guards; native RTL execution is a separate gate."""
from pathlib import Path
import copy
import json
import unittest
from unittest.mock import patch

import prepare_pipe_wait_read_ack as recipe
import run_pipe_wait_read_ack_leaf as leaf
import run_pipe_wait_mixed as mixed

PARENT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/demand-size-core-r1/candidate')


class PipeWaitReadAck(unittest.TestCase):
    def test_exact_reversible_hardware_delta(self):
        old = (PARENT/recipe.FILE).read_text()
        new = recipe.transform(old)
        self.assertEqual(new.replace(recipe.NEW+recipe.WITNESS,recipe.OLD),old)
        hardware = new.replace(recipe.WITNESS,'')
        self.assertEqual(hardware.replace(recipe.NEW,recipe.OLD),old)
        self.assertIn('(pipe_store_req && !mem_ack)',recipe.NEW)
        self.assertIn('pipe_mem_wait === pipe_wait_before_read_ack',recipe.WITNESS)
        self.assertIn('!mem_we && (mem_read_ack === mem_ack)',recipe.WITNESS)

    def test_drift_and_reapplication_rejected(self):
        old = (PARENT/recipe.FILE).read_text()
        for source in (old+'\n',recipe.transform(old),old.replace(recipe.OLD,'')):
            with self.assertRaises(ValueError): recipe.transform(source)

    def test_fixture_uses_actual_complete_equations(self):
        core = (PARENT/recipe.FILE).read_text()
        bus = (PARENT/'rtl/core/core_bus_driver.svh').read_text()
        template = Path(leaf.__file__).with_name('pipe_wait_read_ack_leaf.svh').read_text()
        fixture = leaf.fixture(core,bus,template)
        for name in ('fx_hold_e','mem_ack'):
            self.assertIn(leaf.assignment(core,name),fixture)
        for text in leaf.extraction.extract(core,bus): self.assertIn(text,fixture)
        for marker in ('FRONTEND','REQUESTS','BRANCH','FRAGMENT','REFERENCE','CANDIDATE'):
            self.assertNotIn('\n'+marker+'\n',fixture)
        self.assertIn('mutant==1',fixture)
        self.assertIn('mutant==2',fixture)
        self.assertIn('mutant==3',fixture)
        self.assertIn('mutant==4',fixture)
        self.assertEqual(3*2**22+2*128*8,leaf.SAMPLES)

    def test_closed_native_evidence_regrades(self):
        root = (PARENT.parent.parent/'pipe-wait-leaf-r1').resolve(strict=True)
        self.assertIn(str(root/'core.sv'),leaf.check_receipt(root))

    def test_incomplete_unwaited_or_ineffective_evidence_rejected(self):
        root = (PARENT.parent.parent/'pipe-wait-leaf-r1').resolve(strict=True)
        text = (root/'closed.json').read_text()
        original = json.loads(text)
        variants = []
        bad=copy.deepcopy(original); bad['rows'].pop(); variants.append(bad)
        bad=copy.deepcopy(original); bad['rows'][1]['native_exit']=0; variants.append(bad)
        bad=copy.deepcopy(original); bad['rows'][0]['actual_wait']=False; variants.append(bad)
        bad=copy.deepcopy(original); bad['rows'][0]['counts']['held_reads']=0; variants.append(bad)
        bad=copy.deepcopy(original); bad['memory_events']['oom_kill']='1'; variants.append(bad)
        actual_load = json.loads
        for changed in variants:
            with patch.object(leaf.json,'loads',side_effect=lambda s: changed if s==text else actual_load(s)):
                with self.assertRaises(AssertionError): leaf.check_receipt(root)

    def test_mixed_store_corpus_requires_readback_and_actual_v(self):
        text = mixed.adapted_main()
        compile(text, mixed.__file__, 'exec')
        self.assertIn("movl '+operand+',%ebx", text)
        self.assertIn('cmpl %esi,%ebx', text)
        self.assertIn("'mixed V store not exercised'", text)
        self.assertIn("if label in ('same-bank','split'): assert memory_v==0", text)
        self.assertIn("assert both['control']==both['candidate']", text)
        self.assertIn("compare.compare_func(gold,tr,False,0xffffffff,False,20,log,sys_both=True)==0", text)

    def test_closed_mixed_corpus_covers_owners(self):
        root = (PARENT.parent.parent/'pipe-wait-mixed-r1').resolve(strict=True)
        done = json.loads((root/'closed.json').read_text())
        self.assertTrue(done['passed'] and done['pins_unchanged'])
        self.assertFalse(done['errors'])
        self.assertEqual(len(done['measurements']), 144)
        self.assertGreater(done['memory_v_retirements'], 0)
        self.assertGreater(done['wait_held'], 0)
        self.assertGreater(done['wait_paired'], 0)


if __name__ == '__main__': unittest.main()
