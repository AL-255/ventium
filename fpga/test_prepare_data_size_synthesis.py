"""Check exact parent identities and unchanged synthesis/report resource guards."""
import ast
import unittest

import prepare_data_size_synthesis as p


class PreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        for name, digest in p.TEMPLATES.items():
            path = p.PARENT / name
            if p.sha(path) != digest: raise AssertionError('template drift: ' + name)
            cls.original[name] = path.read_text()

    def test_matched_one_file_transfer(self):
        out = p.derive(self.original)
        self.assertEqual(len(out), 5)
        self.assertEqual(list(p.CHANGES), ['ventium/rtl/core/core.sv'])
        for phase in ('synthesis', 'clock'):
            text = out[phase + '-r1/run.py']; ast.parse(text)
            self.assertIn("'data_size_timing'", text)
            self.assertIn("VEN_FPGA_CORE_MHZ='40'", text)
            boundary = 'owner = None\n'; old = self.original[phase + '-r1/run.py']
            self.assertEqual(text[text.index(boundary):], old[old.index(boundary):])
        self.assertIn(p.PARENT_DCP, out['clock-r1/run.py'])
        self.assertIn('(-2.889)', out['clock-r1/audit_closed.py'])
        self.assertEqual(out['clock-r1/audit.tcl'], self.original['clock-r1/audit.tcl'])

    def test_acceptance_and_reserves_retained(self):
        text = p.derive(self.original)['synthesis-r1/run.py']
        for required in ("func['functional_passes']==108", "not func['canonical_gate_passed']",
                         "func['fetch_boundary_cases']==22", "pc['structural_debt_count']==98",
                         '[4767218,4753406]', 'assert shutil.disk_usage(root).free > 6*gib',
                         'shutil.disk_usage(root).free-4*gib > 2*measured_disk_growth',
                         "host['MemAvailable'] > 10*gib and host['SwapFree'] > 10*gib",
                         'hardware_acceptance=False,implementation_authorized_by_this_controller=False'):
            self.assertIn(required, text)

    def test_guard_mutations_rejected(self):
        for phase, guard, before, after in (
            ('synthesis', p.guarded, "VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='7G'"),
            ('clock', p.clock_guarded, "VENTIUM_VIVADO_MEMORY_SWAP_MAX='4G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'")):
            old = self.original[phase + '-r1/run.py']
            with self.assertRaises(AssertionError): guard(old.replace(before, after), old)
            with self.assertRaises(AssertionError): guard(old.replace('process.wait(timeout=90)', 'process.wait(timeout=900)'), old)


if __name__ == '__main__': unittest.main()
