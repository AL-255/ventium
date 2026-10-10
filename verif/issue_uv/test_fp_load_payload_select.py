"""Source guards, not substitutes for native payload/whole-core verification."""
from pathlib import Path
import unittest

import prepare_fp_load_payload_select as recipe


class LoadPayloadRecipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (Path(__file__).resolve().parents[2]/'rtl/core/core.sv').read_text()

    def test_default_off_original_text_retained(self):
        new = recipe.transform(self.source)
        marker = '`ifdef '+recipe.FLAG+'\n'
        begin = new.index(marker)
        end = new.index('\n`else\n'+recipe.OLD+'\n`endif', begin)
        disabled = new[:begin]+recipe.OLD+new[end+len('\n`else\n'+recipe.OLD+'\n`endif'):]
        self.assertEqual(disabled, self.source)

    def test_no_late_ack_in_payload_logic(self):
        code = '\n'.join(line.split('//', 1)[0] for line in recipe.NEW.splitlines())
        for token in ('mem_ack', 'fp_load64_take', 'fp_shared_load_cmd', 'fsm_case_enabled'):
            self.assertNotIn(token, code)

    def test_valid_operand_comparison_not_removed(self):
        new = recipe.transform(self.source)
        self.assertIn('fp_shared_cmd_valid &&', new)
        self.assertIn('fp_shared_cmd_mem !== fp_shared_cmd_mem_reference', new)
        self.assertIn('FP-LOAD-PAYLOAD-OWNER', new)

    def test_refuse_changed_ownership_and_double_application(self):
        for marker in recipe.GUARDS:
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                recipe.transform(self.source.replace(marker, ''))
        with self.assertRaises(ValueError):
            recipe.transform(recipe.transform(self.source))


if __name__ == '__main__':
    unittest.main()
