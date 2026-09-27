import unittest
from pathlib import Path
from fpd_layout import layout


class LayoutTest(unittest.TestCase):
    def test_order_comments(self):
        self.assertEqual(layout('typedef struct packed { logic a; // hi\n'
                                'logic [31:0] b; /* tail */ logic [2:0] c; } fpd_t;'),
                         [('a', 35, 1), ('b', 3, 32), ('c', 0, 3)])

    def test_reject_unknown(self):
        for body in ('int a;', 'logic [7:1] a;', 'logic a; logic a;'):
            with self.assertRaises(ValueError):
                layout('typedef struct packed {' + body + '} fpd_t;')

    def test_current_layout(self):
        package = Path(__file__).resolve().parents[1] / 'rtl/core/ventium_decode_pkg.sv'
        fields = layout(package.read_text())
        self.assertEqual(sum(width for _, _, width in fields), 210)
        self.assertEqual(fields[0], ('simple', 209, 1))
        self.assertEqual(fields[-1], ('is_fxch_free', 0, 1))


if __name__ == '__main__':
    unittest.main()
