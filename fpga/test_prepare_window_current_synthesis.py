"""Check source-specific timing preparation without relaxing resource guards."""
import ast
import unittest

import prepare_window_current_synthesis as p


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        for name, digest in p.TEMPLATES.items():
            path = p.ROOT/name
            if p.sha(path) != digest: raise AssertionError('template drift: '+name)
            cls.original[name] = path.read_text()

    def test_matched_two_file_transfer(self):
        out = p.derive(self.original)
        self.assertEqual(len(out), 5)
        self.assertEqual(list(p.CHANGES), ['ventium/rtl/core/decode_stages.sv', 'ventium/rtl/mem/ven_l1d.sv'])
        for phase in ('synthesis', 'clock'):
            text = out['window-current-'+phase+'-r1/run.py']; ast.parse(text)
            self.assertIn("'window_current_timing'", text)
            self.assertIn("VEN_FPGA_CORE_MHZ='40'", text)
            boundary = 'owner = None\n'; old = self.original[phase+'-r1/run.py']
            self.assertEqual(text[text.index(boundary):], old[old.index(boundary):])
        self.assertIn(p.PARENT_DCP, out['window-current-clock-r1/run.py'])
        self.assertIn('(-2.909)', out['window-current-clock-r1/audit_closed.py'])
        self.assertEqual(out['window-current-clock-r1/audit.tcl'], self.original['clock-r1/audit.tcl'])

    def test_acceptance_and_reserves_retained(self):
        text = p.derive(self.original)['window-current-synthesis-r1/run.py']
        for value in ("func['functional_passes']==108", "not func['canonical_gate_passed']",
                      "len(fault['rows'])==44", "pc['structural_debt_count']==98",
                      '[4767218,4753406]', 'assert shutil.disk_usage(root).free > 6*gib',
                      'shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth',
                      "host['MemAvailable'] > 10*gib and host['SwapFree'] > 10*gib",
                      'hardware_acceptance=False,implementation_authorized_by_this_controller=False'):
            self.assertIn(value, text)

    def test_guard_mutations_rejected(self):
        for phase, guard, before, after in (
            ('synthesis', p.guarded, "VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='7G'"),
            ('clock', p.clock_guarded, "VENTIUM_VIVADO_MEMORY_SWAP_MAX='4G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'")):
            old = self.original[phase+'-r1/run.py']
            with self.assertRaises(AssertionError): guard(old.replace(before, after), old)
            with self.assertRaises(AssertionError): guard(old.replace('process.wait(timeout=90)', 'process.wait(timeout=900)'), old)


if __name__ == '__main__': unittest.main()
