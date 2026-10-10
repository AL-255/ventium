import unittest
from pathlib import Path

from prepare_native_gpr_observer import transform


class NativeGprObserver(unittest.TestCase):
    def setUp(self):
        self.source = Path(__file__).with_name('native_x87_at_pc.c').read_text()

    def test_passive_integer_and_exit_observation(self):
        fixed = transform(self.source)
        for name, member in (('eax','rax'), ('ebx','rbx'), ('ecx','rcx'), ('edx','rdx'),
                             ('esi','rsi'), ('edi','rdi'), ('ebp','rbp'), ('esp','rsp'), ('eip','rip')):
            self.assertIn(f'GPR("{name}", {member});', fixed)
        for forbidden in ('PTRACE_SETREGS', 'PTRACE_SETFPREGS', 'PTRACE_POKETEXT', 'PTRACE_POKEDATA'):
            self.assertNotIn(forbidden, fixed)
        self.assertIn('PTRACE_O_EXITKILL | PTRACE_O_TRACEEXIT', fixed)
        self.assertIn('dump_gpr("gprs_before", &regs)', fixed)
        self.assertIn('dump_gpr("gprs_after", &after_regs)', fixed)
        self.assertEqual(fixed.count('request(PTRACE_GETREGS,'), 2)
        self.assertIn('WIFEXITED(status) || WEXITSTATUS(status)', fixed)

    def test_refuse_source_drift_or_double_application(self):
        for source in ('', self.source+self.source, transform(self.source)):
            with self.assertRaises(ValueError):
                transform(source)


if __name__ == '__main__':
    unittest.main()
