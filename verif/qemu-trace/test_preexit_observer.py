"""Fail-closed source-recipe guards; native qualification is separate."""
from pathlib import Path
import unittest
from prepare_preexit_observer import ENTRY, EXIT, INCLUDE, HELPER, host_compat, transform

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/linux-user/syscall.c'


class SourceGuards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = SOURCE.read_text()

    def test_only_observation_added(self):
        fixed = transform(self.original)
        restored = fixed.replace('#include "gdbstub/user.h"\n', '')
        restored = restored.replace(HELPER, '').replace('        vtm_gdb_preexit(cpu);\n', '')
        self.assertEqual(restored, self.original)
        self.assertEqual(fixed.count('        vtm_gdb_preexit(cpu);\n'), 2)
        self.assertIn('strcmp(enabled, "1") == 0', fixed)

    def test_no_architectural_assignment(self):
        self.assertNotIn('env->', HELPER)
        self.assertNotIn('cpu_env->', HELPER)
        self.assertNotIn('regs[', HELPER)
        self.assertIn('gdb_handlesig(cpu, TARGET_SIGTRAP)', HELPER)

    def test_host_compat_only_renames_private_tag(self):
        fixed = host_compat(self.original)
        self.assertEqual(fixed.replace('struct vtm_qemu_sched_attr', 'struct sched_attr'),
                         self.original)
        self.assertEqual(transform(fixed), host_compat(transform(self.original)))
        with self.assertRaises(ValueError): host_compat(fixed)
        with self.assertRaises(ValueError): host_compat(self.original + 'struct sched_attr')

    def test_duplicate_recipe_refused(self):
        with self.assertRaises(ValueError): transform(transform(self.original))

    def test_missing_and_ambiguous_anchors_refused(self):
        for anchor in (INCLUDE, ENTRY, EXIT):
            with self.subTest(anchor=anchor):
                with self.assertRaises(ValueError): transform(self.original.replace(anchor, '', 1))
                with self.assertRaises(ValueError): transform(self.original + anchor)

    def test_exit_context_drift_refused(self):
        for anchor in ('        _exit(arg1);', '        return get_errno(exit_group(arg1));'):
            with self.subTest(anchor=anchor):
                with self.assertRaises(ValueError): transform(self.original.replace(anchor, ''))


if __name__ == '__main__': unittest.main()
