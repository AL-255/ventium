"""Controller derivation checks; no Vivado or board operations."""
import unittest
import prepare_parallel_write_implementation as recipe


class Implementation(unittest.TestCase):
    def setUp(self):
        self.original = (recipe.OLD/'run_implementation.py').read_text()

    def test_exact_template_drift_rejected(self):
        with self.assertRaises(AssertionError): recipe.derive(self.original+'\n')

    def test_only_native_launch_is_existing_implementation(self):
        text = recipe.derive(self.original)
        self.assertEqual(text.count('subprocess.Popen(command'),1)
        self.assertIn("project = root/'project/rk_ao486_system.xpr'",text)
        self.assertNotIn("audit_closed =",text)
        self.assertNotIn('reset_run',text)
        self.assertIn('stop_disk_floor=4*gib',text)
        self.assertIn('if free < 4*gib:',text)
        self.assertIn('free > 8*gib',text)

    def test_monitor_and_closure_unchanged_except_disk_reserve(self):
        marker = 'owner = None\n'
        expected = self.original[self.original.index(marker):].replace(
            'if free < 2*gib:', 'if free < 4*gib:')
        text = recipe.derive(self.original)
        self.assertEqual(text[text.index(marker):],expected)


if __name__ == '__main__': unittest.main()
