import ast
import unittest

import run_next_ready_coremark as runner
import audit_next_ready_coremark as audit


class CoreMarkTests(unittest.TestCase):
    def test_no_cycle_gain_or_regression_hidden(self):
        for seed, ticks in runner.TICKS.items():
            self.assertEqual(runner.cost(seed, ticks)['added_clocks'], 0)
            for bad in (ticks-1, ticks+1, 0):
                with self.assertRaises(AssertionError): runner.cost(seed, bad)

    def test_original_completion_and_uv_checks_retained(self):
        text = runner.derive(); ast.parse(text)
        for token in ("iterations=10", 'reference_crcs=crcs', 'require_valid_duration=False',
                      "int(samples[-1][4])>0", 'observe_owned_native(', 'VEN_SYS_FASTPATH_RELOC',
                      "standard_suite=False", 'result.update(cost(seed,'):
            self.assertIn(token, text)
        self.assertNotIn("started['cycle_cost']", text)
        self.assertIn('ventium-next-ready-cm10-', text)

    def test_independent_audit_replays_exact_clock_check(self):
        text = audit.derive(); ast.parse(text)
        self.assertIn('runner.cost(seed,result[', text)
        self.assertIn("native['affinity'] == [12]", text)
        self.assertIn("root = soc / 'coremark-r1'", text)


if __name__ == '__main__': unittest.main()
