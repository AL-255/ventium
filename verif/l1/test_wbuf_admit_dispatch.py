import unittest
from pathlib import Path
from prepare_wbuf_admit_dispatch import transform


class AdmitDispatchRecipe(unittest.TestCase):
    def test_preserves_empty_and_existing_queue_priority(self):
        source=(Path(__file__).resolve().parents[2]/'rtl/mem/ven_axi_master.sv').read_text()
        text=transform(source)
        self.assertIn('!wr_dispatch && ((wq_count',text)
        self.assertIn('wr_head_payload_done &&',text)
        self.assertIn('|| wr_second_payload_done)',text)
        self.assertIn("if (!wr_launch) wr_active <= 1'b0;",text)
        self.assertNotIn('VEN_P54_WBUF_EMPTY_DISPATCH',text)
        self.assertIn('localparam int unsigned P5_WBUF_DEPTH = 2;',text)

    def test_double_application_refused(self):
        source=(Path(__file__).resolve().parents[2]/'rtl/mem/ven_axi_master.sv').read_text()
        with self.assertRaises(ValueError):transform(transform(source))


if __name__=='__main__':unittest.main()
