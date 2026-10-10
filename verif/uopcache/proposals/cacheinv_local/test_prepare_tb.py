import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
spec = importlib.util.spec_from_file_location('prepare_cacheinv_tb', HERE / 'prepare_tb.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class TestShell(unittest.TestCase):
    def setUp(self):
        self.decoder = (REPO / 'rtl/core/decode_stages.sv').read_text()
        self.core = (REPO / 'rtl/core/core.sv').read_text()
        self.body = (HERE / 'body.svh').read_text()

    def test_real_ports(self):
        prefix, shell = m.generate(self.decoder, self.core, self.body)
        self.assertIn('} sysop_e;', prefix)
        self.assertIn('} state_e;', prefix)
        self.assertIn('.ibuf(reference_bytes)', shell)
        self.assertIn('.d_cacheinv(d_cacheinv)', shell)
        self.assertIn('.d_unknown(d_unknown)', shell)
        self.assertNotIn('// GENERATED_INPUT_DEFAULTS', shell)
        self.assertNotIn('module core', prefix)

    def test_drift_refused(self):
        for decoder, core, body in (
            (self.decoder.replace('d_unknown,', 'another_unknown,'), self.core, self.body),
            (self.decoder, self.core.replace('} state_e;', '} changed_e;'), self.body),
            (self.decoder, self.core, self.body.replace('// GENERATED_INPUT_DEFAULTS', '')),
            (self.decoder.replace('input  logic [7:0]  ibuf [16],', 'input BAD PORT,'), self.core, self.body),
        ):
            with self.subTest(decoder=decoder[:20]):
                with self.assertRaises(ValueError): m.generate(decoder, core, body)


if __name__ == '__main__':
    unittest.main()
