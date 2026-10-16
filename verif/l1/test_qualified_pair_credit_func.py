"""Keep the functional model binding and reference/comparison policy exact."""
import unittest

import audit_qualified_pair_credit_func as audit
import run_qualified_pair_credit_func as run


class Functional(unittest.TestCase):
    def test_source_binding_and_unchanged_worker(self):
        text = run.derive_functions()
        scope = dict(run.template.previous.__dict__, __file__=run.__file__, MODEL=run.MODEL)
        exec(compile(text, run.__file__, 'exec'), scope)
        old = run.SOURCE.read_text()
        changed, substitutions = scope['derive'](old)
        for before, after in reversed(substitutions):
            changed = changed.replace(after, before)
        self.assertEqual(changed, old)
        for token in ("start['changes'] == CHANGES", 'recipe.PINS', 'set(range(4,8))',
                      "assert sha(build/'build/qemu-i386') == REFERENCE", 'canonical_gate_passed=False'):
            self.assertIn(token, text)

    def test_audit_preserves_unmasked_check_and_native_witnesses(self):
        text = audit.derive()
        for token in ('qualified-pair-credit-func-r1', 'qualified-pair-credit-core-r1',
                      "cpu in range(4,8)", 'same_elf_except_gcc_file_symbol',
                      'affinity_verified', 'unmasked_functional_passes=105',
                      'canonical_gate_passed=False'):
            self.assertIn(token, text)


if __name__ == '__main__':
    unittest.main()
