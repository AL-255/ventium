"""Pure exact-source recipe checks; native decoder/datapath checks are separate."""
import hashlib
import os
from pathlib import Path
import unittest
from prepare_u_shift_registers import transform, extract, PARENT, ASSERTION, BEGIN, END


class Recipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ['U_SHIFT_PARENT']).read_text()

    def test_exact_scope(self):
        self.assertEqual(hashlib.sha256(self.source.encode()).hexdigest(), PARENT)
        changed = transform(self.source)
        self.assertEqual(self.source.split(BEGIN)[0], changed.split(BEGIN)[0])
        self.assertEqual(self.source.split(END)[1], changed.split(END)[1])
        self.assertIn(ASSERTION, changed)

    def test_drift_and_reapplication(self):
        for bad in (self.source+'\n', transform(self.source)):
            with self.assertRaises(ValueError):
                transform(bad)

    def test_extraction(self):
        block = extract(transform(self.source), 'candidate_u')
        self.assertIn('function automatic logic [31:0] reg_read', block)
        self.assertIn('u_shift_cnt = pipe_u_eff.shift_cl ? u_src_reg_val[4:0]', block)
        self.assertNotIn('U-SHIFT-REGISTER-OWNER', block)
        self.assertNotIn(END, block)


if __name__ == '__main__':
    unittest.main()
