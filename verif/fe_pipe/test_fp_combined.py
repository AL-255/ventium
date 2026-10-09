#!/usr/bin/env python3
"""The integration driver may not weaken the original functional assertions."""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('combined', HERE/'run-fp-combined-mem64.py')
combined = importlib.util.module_from_spec(spec)
spec.loader.exec_module(combined)


class CombinedRunner(unittest.TestCase):
    def test_preserves_checks_and_sources(self):
        text = combined.BASE.read_text()
        result = combined.transform(text)
        compile(result, '<combined>', 'exec')
        for check in (
            'assert compare_complete(gold, trace, log) == 0',
            "assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]",
            "assert b['total_clocks'] <= a['total_clocks']",
            "assert sum(b['warm_clocks']) <= sum(a['warm_clocks'])",
            "assert row['queued'] == 0 and row['integer_overlap'] == 0",
            "assert 'VEN_FP_MEM_QUEUE64' not in profiles['control']",
        ):
            self.assertIn(check, result)
        self.assertIn("assert 'VEN_FP_SCALAR_DISPATCH' not in profiles['control']", result)
        self.assertIn('for p in (Path(__file__), BASE, source, linker, qemu,', result)
        self.assertEqual(combined.BASE.read_text(), text)

    def test_source_drift_rejected(self):
        text = combined.BASE.read_text()
        for value in ('', text+text, combined.transform(text),
                      text.replace("                if case[1]:\n", '')):
            with self.subTest(text=value[:20]), self.assertRaises(ValueError):
                combined.transform(value)


if __name__ == '__main__':
    unittest.main()
