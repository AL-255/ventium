"""Verify the private replay cannot silently change the existing comparison."""
import unittest

import run_v_result_carry_func as p


class FunctionalReplay(unittest.TestCase):
    def test_only_identity_and_cpu_assignment_change(self):
        source = p.SOURCE.read_text()
        text, changes = p.derive(source)
        self.assertEqual(len(changes), 4)
        for old, new in reversed(changes):
            text = text.replace(new, old)
        self.assertEqual(text, source)

    def test_uv_fast_axi_and_complete_corpus_retained(self):
        text, _ = p.derive(p.SOURCE.read_text())
        for expected in ('--cycle-func --l1-axi', "AXI_RLAT='7',AXI_WLAT='7'",
                         "VTM_QEMU_GDB_PREEXIT='1'", "len(jobs)==len({j[1] for j in jobs})==108",
                         'canonical_gate_passed=False', 'os.killpg(child.pid,signal.SIGKILL)',
                         'affinity==[cpu]', 'cpu=12+index%4'):
            self.assertIn(expected, text)

    def test_reference_worker_drift_rejected(self):
        with self.assertRaises(AssertionError):
            p.derive(p.SOURCE.read_text().replace("fields[3]=='PASS'", 'True'))


if __name__ == '__main__':
    unittest.main()
