"""Check candidate binding, fixed oracle policy, and native driver preservation."""
import inspect
import unittest
import run_system_read_ack_func as runner
import audit_system_read_ack_func as audit


class Functional(unittest.TestCase):
    def test_exact_driver_adaptation(self):
        scope=dict(runner.previous.__dict__,__file__=runner.__file__,MODEL=runner.MODEL)
        exec(compile(runner.derive_functions(),runner.__file__,'exec'),scope)
        original=runner.SOURCE.read_text()
        changed,substitutions=scope['derive'](original)
        recovered=changed
        for before,after in reversed(substitutions):recovered=recovered.replace(after,before)
        self.assertEqual(recovered,original)
        self.assertIn('set(range(4,8))',changed)
        self.assertIn('cpu=4+index%4',changed)
        self.assertIn("TB_EXTRA_FLAGS='--cycle-func --l1-axi'",changed)
        self.assertIn("VTM_QEMU_GDB_PREEXIT='1'",changed)
        self.assertIn(runner.MODEL,changed)
        self.assertIn('native_worker_exit=code',changed)

    def test_nine_file_source_binding_and_grade(self):
        source=runner.derive_functions()
        self.assertIn("start['changes'] == CHANGES",source)
        self.assertIn('n.removeprefix(recipe.PREFIX)',source)
        self.assertIn("assert sha(build/'build/qemu-i386') == REFERENCE",source)
        self.assertIn('canonical_gate_passed=False',source)
        grade=audit.derive()
        for token in ('system-read-ack-func-r1','system-read-ack-core-r1',
                      'import run_system_read_ack_func as runner',"cpu in range(4,8)"):
            self.assertIn(token,grade)


if __name__=='__main__':unittest.main()
