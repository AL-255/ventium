"""The generated-PC alias correction must not change the host contract."""
import unittest
import build_retained_ui_bound_soc as b


class Binding(unittest.TestCase):
    def test_exact_named_wire_change(self):
        old = (b.prior.host_recipe.HERE/'pc_keyboard_retained.h').read_text()
        new = b.binding(old)
        self.assertEqual(new.replace('p.read_request=K(kb_fifo_rdreq);',
            'p.read_request=K(__Vcellinp__keyb_fifo__rdreq);'), old)
        self.assertEqual(new.count('K(kb_fifo_rdreq)'), 1)
        with self.assertRaises(AssertionError): b.binding(new)
        with self.assertRaises(AssertionError): b.binding(old+'\n')


if __name__ == '__main__': unittest.main()
