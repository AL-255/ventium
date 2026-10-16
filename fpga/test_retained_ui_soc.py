"""Guard the isolated controller/input-host transfer, not UI acceptance."""
from pathlib import Path
import unittest

import build_retained_ui_soc as b

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class RetainedUI(unittest.TestCase):
    def test_host_uses_explicit_retained_contract(self):
        original=(b.host_recipe.PARENT/b.host_recipe.MAIN).read_text()
        adapted=b.transform_host(original)
        self.assertIn('#include "pc_keyboard_retained.h"',adapted)
        for name in ('before','after'):
            self.assertIn(f'ven_ui::pc_keyboard_retained_{name}(',adapted)
            self.assertNotIn(f'ven_ui::pc_keyboard_{name}(',adapted)
        for token in ('top->eval();','set_clocks(0);','set_clocks(1);','tick();','ps2_mouse_drive();'):
            self.assertEqual(adapted.count(token),original.count(token),token)
        pixels=original.split('    auto DAC =',1)[1].split('    fclose(f);',1)[0]
        self.assertIn('    auto DAC ='+pixels,adapted)
        self.assertIn('ven_ui::forbidden_ui_option(argv[i])',adapted)
        with self.assertRaises(ValueError):b.transform_host(original+'\n')

    def test_only_controller_source_changes(self):
        parent=b.host_recipe.PARENT.resolve();child=ROOT/'retained-ui-soc-r1'
        prepared=b.load(child/'prepared.json');self.assertTrue(b.stable(prepared['pins']))
        self.assertEqual(prepared['processor_rtl_changes'],[])
        self.assertEqual(prepared['added_defines'],[])
        changes=sorted(str(p.relative_to(parent/'source')) for p in (parent/'source').rglob('*')
            if p.is_file() and b.sha(p)!=b.sha(child/'source'/p.relative_to(parent/'source')))
        self.assertEqual(changes,[b.PS2])
        self.assertEqual(b.sha(child/'source'/b.PS2),b.PS2_SHA)
        self.assertFalse(prepared['original_transport_gate_passed'])
        self.assertFalse(prepared['full_pc_input_qualified'])

    def test_closed_real_controller_and_host_evidence(self):
        pins=b.evidence(ROOT)
        for name in ('retained-rtl-r1','retained-host-r1','ps2-loss-aux-extended-r2'):
            self.assertIn(str(ROOT/name/'closed.json'),pins)


if __name__=='__main__':unittest.main()
