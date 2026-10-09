import unittest
from pathlib import Path
from prepare_wbuf_empty_dispatch import transform


class EmptyDispatchRecipe(unittest.TestCase):
    def setUp(self):
        self.source = (Path(__file__).resolve().parents[2] /
                       'rtl/mem/ven_axi_master.sv').read_text()

    def test_bounded_registered_path(self):
        text = transform(self.source)
        self.assertIn("(wq_count == WBUF_CNTW'(0))", text)
        self.assertIn('wr_empty_dispatch = wr_enq && !wr_active', text)
        self.assertIn('wr_active_slot <= wr_launch_slot;', text)
        self.assertIn('localparam int unsigned P5_WBUF_DEPTH = 2;', text)
        self.assertEqual(text.count('assign wr_enq'), self.source.count('assign wr_enq'))
        self.assertEqual(text.count('assign wq_head_release'), self.source.count('assign wq_head_release'))

    def test_refuses_reapplication(self):
        with self.assertRaises(ValueError):
            transform(transform(self.source))

    def test_refuses_missing_payload(self):
        with self.assertRaises(ValueError):
            transform(self.source.replace('wr_active_slot <= wr_dispatch_slot', 'wr_active_slot <= 0'))

    def test_refuses_ambiguous_anchor(self):
        with self.assertRaises(ValueError):
            transform(self.source + self.source)


if __name__ == '__main__':
    unittest.main()
