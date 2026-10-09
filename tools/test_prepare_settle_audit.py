#!/usr/bin/env python3
"""The instrumentation may observe extra state, never remove an evaluation."""
import unittest
from prepare_settle_audit import instrument
from prepare_inactive_board_settle import prepare

EDGE = '''        if (args.skip_unchanged_settle) {
            ++mandatory_edge_evals;
            input_snapshot.capture(*top);
        }'''
GUARD = '''    if (args.skip_unchanged_settle) {
        return 2; // Admission must remain identical.
    }
'''
FIXTURE = '''#include "model_input_snapshot.h"
''' + GUARD + '''    // Do this after parsing
    auto same_clock_settle = [&]() {
        if (args.skip_unchanged_settle) {
            ++skipped_settle_evals;
            return;
        }
        top->eval();
    };
''' + EDGE + '\n' + EDGE


class PreparationTests(unittest.TestCase):
    def test_preserves_admission(self):
        output = instrument(FIXTURE)
        self.assertIn(GUARD, output)
        self.assertNotIn('++skipped_settle_evals;', output)
        self.assertEqual(output.count('++mandatory_edge_evals;'), 2)
        self.assertEqual(output.count('input_snapshot.capture(*top);'), 3)
        self.assertIn('!top->eventsPending() && input_snapshot.matches(*top)', output)
        self.assertIn('settle_audit.eval(*top', output)

    def test_missing_include_fails(self):
        with self.assertRaises(ValueError):
            instrument(FIXTURE.replace('#include "model_input_snapshot.h"', ''))

    def test_ambiguous_include_fails(self):
        with self.assertRaises(ValueError):
            instrument('#include "model_input_snapshot.h"\n' + FIXTURE)

    def test_missing_edge_fails(self):
        with self.assertRaises(ValueError):
            instrument(FIXTURE.replace(EDGE, '', 1))

    def test_unknown_settle_fails(self):
        with self.assertRaises(ValueError):
            instrument(FIXTURE.replace('++skipped_settle_evals;', ''))


PRIVATE_FIXTURE = '''#include "model_input_snapshot.h"
#if defined(VEN_L1_AXI) || defined(VEN_DBG_CORE) || defined(VEN_DOS_MODELS) || defined(VEN_XOVER)
    return 2;
#endif
    if (args.system || args.cosim || args.l1_axi) return 2;
    // Do this after parsing
    ModelInputSnapshot input_snapshot;
    auto same_clock_settle = [&]() {
        original_settle_logic();
    };
            static uint32_t prev_fpc = 0xFFFFFFFFu;
            if (fpc != prev_fpc) {
                original_fault_report();
                prev_fpc = fpc;
            }
    top->final();
'''


class PrivatePreparationTests(unittest.TestCase):
    def test_narrow_admission_and_real_delivery_counter(self):
        output = prepare(PRIVATE_FIXTURE)
        self.assertIn('#if defined(VEN_DOS_MODELS) || defined(VEN_XOVER)', output)
        self.assertIn('if (args.system || args.cosim || args.l1_axi) return 2;', output)
        self.assertIn('require_inactive_board_settle(*top);', output)
        self.assertIn('inactive_board_settle_environment(environ)', output)
        self.assertIn('original_settle_logic();', output)
        self.assertIn('original_fault_report();', output)
        self.assertNotIn('prev_fpc', output)
        self.assertIn('fault_deliveries.observe(', output)
        self.assertNotIn('mem.restore(', output)
        self.assertNotIn('VerilatedRestore', output)

    def test_unrecognized_harness_fails_closed(self):
        for anchor in ('    top->final();', '    ModelInputSnapshot input_snapshot;',
                       '            if (fpc != prev_fpc) {'):
            with self.subTest(anchor=anchor), self.assertRaises(ValueError):
                prepare(PRIVATE_FIXTURE.replace(anchor, ''))


if __name__ == '__main__':
    unittest.main()
