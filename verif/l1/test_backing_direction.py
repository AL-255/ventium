"""Source guards for the private backing-direction experiment."""
from pathlib import Path
import re
import unittest

import prepare_backing_direction as recipe
import run_backing_direction_leaf as leaf
import run_backing_direction_axi as axi
import build_backing_direction_core as core

SOURCE=leaf.ROOT/'v-result-carry-posted-mouse-fpga-r1/ventium/rtl/mem/ven_l1d.sv'


class Direction(unittest.TestCase):
    def test_exact_delta_and_default(self):
        old=SOURCE.read_text(); new=recipe.transform(old)
        self.assertEqual(new.replace(recipe.changed_block(old),recipe.block(old),1).replace(
            recipe.NEW_WITNESS,recipe.OLD_WITNESS,1),old)
        self.assertIn('`else\n'+recipe.block(old)+'`endif',new)

    def test_drift_and_reapplication(self):
        old=SOURCE.read_text()
        for text in (old+'\n',recipe.transform(old)):
            with self.assertRaises(ValueError): recipe.transform(text)

    def test_direction_has_no_late_control(self):
        code='\n'.join(s.split('//',1)[0] for s in recipe.DIRECTION.splitlines())
        for name in ('c_req','c_pair_req','c_pair_intent_ready','m_req'):
            self.assertNotRegex(code,r'\b'+name+r'\b')
        self.assertEqual(set(re.findall(r'\b(m_\w+)\s*=',code)),{'m_we'})

    def test_observer_and_negative_controls(self):
        old=SOURCE.read_text(); positive=leaf.fixture(old,'positive')
        self.assertIn("old_m_req === 1'b1 || c_req === 1'b1",positive)
        self.assertIn('old_m_we !== new_m_we',positive)
        self.assertIn('early_hints==0',positive)
        for mode in ('late-direction','fill-write','lost-admission','wrong-payload'):
            self.assertNotEqual(leaf.fixture(old,mode),positive)

    def test_actual_axi_miter_observes_consumed_direction(self):
        tb,traffic=axi.fixture()
        self.assertIn('if ((dut.m_req || c_req) && dut.m_we !== shadow_m_we)',tb)
        for n in ('m_addr','m_wstrb'):
            self.assertIn(f'if (dut.{n} !== shadow_{n})',tb)
        self.assertIn('BACKING-AXI-MISMATCH observable credit',tb)
        self.assertIn('wire c_payload_cacheable=cacheable;',tb)
        self.assertNotIn('.dc_tag[',tb)
        for owner in ('dut','control'):
            for way in (0,1): self.assertIn(f'{owner}.dc_tag_way{way}[s]',tb)
        self.assertIn('if(!c_req && m_we!=shadow_m_we)',traffic)
        self.assertIn('for(int a=0;a<65536;a++)',traffic)

    def test_closed_evidence_and_preserved_build_guards(self):
        pins=core.check_leaf(leaf.ROOT/'backing-direction-leaf-r1')
        self.assertIn(str(leaf.ROOT/'backing-direction-axi-r3/closed.json'),pins)
        text=core.adapted_main()
        compile(text,core.__file__,'exec')
        for guard in ('len(files) == 195','pass_fds=(9,)','--is-active',
                      "definitions == old['definitions']","[recipe.FILE]"):
            self.assertIn(guard,text)


if __name__=='__main__': unittest.main()
