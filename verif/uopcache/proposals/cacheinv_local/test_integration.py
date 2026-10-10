from pathlib import Path
import re
import unittest

from prepare_integration import FLAG, OLD, transform
from test_source_contract import CORE, DEFINES

LEAF = Path(__file__).with_name('ven_cacheinv_local.sv').read_text()
SOURCE = CORE.replace(OLD.lstrip(), OLD)


class Integration(unittest.TestCase):
    def test_disabled_restores_exact_source(self):
        core, fragment = transform(SOURCE, LEAF, DEFINES)
        active = ('`ifdef '+FLAG+'\n  `include "core_cacheinv_local.svh"\n'
                  '  assign cache_inv_go = cache_inv_local && (state == S_DECODE);\n'
                  '`else\n'+OLD+'\n`endif')
        self.assertEqual(core.replace(active, OLD), SOURCE)
        self.assertEqual(core.count(active), 1)
        self.assertIn('logic cache_inv_local;', fragment)
        self.assertNotIn('always_ff', fragment)

    def test_fragment_is_tested_logic(self):
        _, fragment = transform(SOURCE, LEAF, DEFINES)
        fragment = fragment.split('  logic cache_inv_local;\n')[1]
        names = {'cinv_allowed_prefix': 'allowed_prefix', 'cinv_header_match': 'header_match',
                 'cache_inv_local': 'recognized', 'g_cacheinv_local_header': 'g_header'}
        reversed_body = re.sub(r'\b(?:'+'|'.join(names)+r')\b', lambda m:names[m[0]], fragment)
        original_body = LEAF.split(');\n')[1].removesuffix('endmodule\n')
        self.assertEqual(reversed_body, original_body)

    def test_drift_refused(self):
        for leaf in [LEAF.replace('input logic cosim_en, soc_en,', 'input logic wrong,'),
                     LEAF+'module x; endmodule\n',
                     LEAF.replace('  logic [14:0]', '  initial $finish;\n  logic [14:0]')]:
            with self.subTest(leaf=leaf[:20]), self.assertRaises(ValueError):
                transform(SOURCE, leaf, DEFINES)
        for source in [SOURCE+OLD, SOURCE.replace(OLD, OLD+' // VEN_CACHEINV_LOCAL'),
                       SOURCE.replace('state == S_EXEC', 'state == S_DECODE')]:
            with self.subTest(source=source[:20]), self.assertRaises(ValueError):
                transform(source, LEAF, DEFINES)

    def test_double_application_refused(self):
        core, _ = transform(SOURCE, LEAF, DEFINES)
        with self.assertRaises(ValueError): transform(core, LEAF, DEFINES)


if __name__ == '__main__':
    unittest.main()
