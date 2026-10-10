import unittest
from prepare_rem_clz_tree import FLAG, OLD, NEW, transform


class Recipe(unittest.TestCase):
    def source(self):
        return 'before\n'+OLD+'\na=rem_clz64(x); b=rem_clz64(y); c=rem_clz64(z);\nafter\n'

    def test_one_function_only(self):
        source=self.source(); new=transform(source)
        self.assertEqual(new.replace('`ifdef '+FLAG+'\n'+NEW+'\n`else\n'+OLD+'\n`endif',OLD),source)

    def test_refuses_reapply(self):
        with self.assertRaises(ValueError): transform(transform(self.source()))

    def test_refuses_changed_function(self):
        with self.assertRaises(ValueError): transform(self.source().replace("7'd64","7'd63"))

    def test_refuses_extra_caller(self):
        with self.assertRaises(ValueError): transform(self.source()+'d=rem_clz64(w);')

    def test_refuses_missing_caller(self):
        with self.assertRaises(ValueError): transform(self.source().replace('b=rem_clz64(y);',''))

    def test_refuses_duplicate_function(self):
        with self.assertRaises(ValueError): transform(self.source()+OLD)


if __name__=='__main__': unittest.main()
