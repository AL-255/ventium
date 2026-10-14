"""The private oracle binding cannot weaken the original failing gate."""
import unittest

import run_boundary


class Binding(unittest.TestCase):
    def test_original_execution_and_comparison_body(self):
        original = run_boundary.SOURCE.read_text()
        changed = run_boundary.derive()
        # Only the relocated executable's original option-ROM lookup changes
        # inside the execution body. Comparison/exit policy stays byte-exact.
        for before,after in run_boundary.ROM_BINDINGS:
            self.assertEqual(changed.count(after),1)
            changed = changed.replace(after,before)
        marker = '    def run(leaf,name,command,expected=0,latency=0):'
        self.assertEqual(changed[changed.index(marker):],original[original.index(marker):])
        cases = "    kinds=sorted(set(args.kind or range(4)));"
        self.assertIn(cases,changed)
        self.assertIn("pins.update(private_pins)",changed)

    def test_import_environment(self):
        namespace = dict(vars(run_boundary),__name__='import_only')
        exec(compile(run_boundary.derive(),'<boundary-import-check>','exec'),namespace)
        self.assertEqual(namespace['HERE'],run_boundary.SOURCE.parent)
        self.assertTrue(callable(namespace['main']))


if __name__ == '__main__':
    unittest.main()
