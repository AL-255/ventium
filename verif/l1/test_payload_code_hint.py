"""Host source/Boolean checks for a private timing proposal; not an RTL gate."""
import itertools
import os
from pathlib import Path
import unittest

import prepare_payload_code_hint as recipe
import run_payload_code_hint_leaf as native_leaf


def disabled_text(source):
    """Remove ONLY the proposal's conditionals, retaining all existing guards."""
    return recipe.select_hint_branch(source, False)


class SourceAndPredicates(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = Path(os.environ['PAYLOAD_CODE_HINT_PARENT'])
        cls.original = {name: (parent/name).read_text() for name in recipe.HASHES}
        cls.changed = recipe.transform(cls.original)

    def test_flag_off_retains_all_existing_tokens(self):
        for name, before in self.original.items():
            with self.subTest(name=name):
                self.assertEqual(disabled_text(self.changed[name]).split(), before.split())

    def test_drift_in_each_interface_and_reapplication_rejected(self):
        for name in recipe.HASHES:
            wrong = dict(self.original)
            wrong[name] += '\n'
            with self.assertRaises(ValueError):
                recipe.transform(wrong)
        with self.assertRaises(ValueError):
            recipe.transform(self.changed)

    def test_enabled_profile_has_one_complete_shadow_declaration(self):
        text = recipe.select_hint_branch(self.changed['rtl/mem/ven_l1d.sv'], True)
        self.assertEqual(text.count('wire shadow_payload_select ='), 1)
        self.assertIn('wire shadow_payload_select = !rd_payload_match && shadow_valid_q &&\n'
                      "      (c_addr[31:5] == shadow_line_addr_q) && (c_addr[4:0] <= 5'd28);", text)

    def test_control_equations_retained(self):
        for name, anchors in {
            'rtl/core/core.sv': ['  assign mem_code = mem_req && !cur_is_d;'],
            'rtl/mem/ventium_l1_axi.sv': ['  assign l1d_c_req  = seam_core_rst_n && core_req && !core_smram_deny',
                '      .c_code  (core_code),'],
            'rtl/mem/ven_l1d.sv': ['  assign code_access = c_code && !c_we && cacheable && !golden &&',
                '  assign rd_match  = rd_armed && !stream_path && (rd_addr_q == c_addr)',
                '  assign early_match = early_armed && c_req && !c_we &&'],
        }.items():
            for anchor in anchors:
                self.assertEqual(self.changed[name].count(anchor), 1)
        self.assertIn('  assign mem_payload_code = !cur_is_d;', self.changed['rtl/core/core.sv'])

    def test_native_extractor_resolves_shared_guarded_continuation(self):
        for enabled, text in ((False, self.original['rtl/mem/ven_l1d.sv']),
                              (True, self.changed['rtl/mem/ven_l1d.sv'])):
            with self.subTest(enabled=enabled):
                leaf = native_leaf.leaf(text, 'dut', enabled)
                self.assertNotIn(recipe.FLAG, leaf)
                self.assertEqual(leaf.count('assign shadow_payload_select ='), 1)
                self.assertIn("(c_addr[4:0] <= 5'd28);", leaf)
                self.assertIn('early_payload_match ?' if enabled else 'early_match ?', leaf)
                self.assertEqual(leaf.count('always @* begin'), 1)

    def test_wrapper_admission_implication_exhaustive(self):
        seen = 0
        # Independent upstream request and downstream reset/deny/drain gates.
        for enabled, request, data, reset, smram, route, drain, write in itertools.product((False, True), repeat=8):
            old_code = enabled and request and not data
            hint = enabled and not data
            cache_req = reset and enabled and request and not smram and not route and not drain
            if cache_req and not write:
                self.assertEqual(hint, old_code)
                seen += 1
        self.assertEqual(seen, 2)

    def test_naive_replacement_changes_control_during_denied_fetch(self):
        # Counterexample to replacing the upstream-qualified code signal with
        # downstream c_req && kind. The wrapper denied the fetch, not the core.
        core_req, kind, seam_reset, route_deny = True, True, True, True
        old_code = core_req and kind
        cache_req = seam_reset and core_req and not route_deny
        self.assertTrue(old_code)
        self.assertFalse(cache_req and kind)

    def test_raw_hint_must_not_authorize_idle_control(self):
        core_req, kind = False, True
        self.assertFalse(core_req and kind)
        self.assertTrue(kind)


if __name__ == '__main__':
    unittest.main()
