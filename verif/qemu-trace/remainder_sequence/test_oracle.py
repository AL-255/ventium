"""Directed independent expected values and deliberately bad observations."""
import unittest

import oracle


class Oracle(unittest.TestCase):
    def test_exact_and_tie(self):
        three=(0x4000,3<<62);two=(0x4000,1<<63)
        self.assertEqual(oracle.step_errors(three,two,(0x3fff,1<<63),0x200,False),[])
        self.assertEqual(oracle.step_errors(three,two,(0xbfff,1<<63),0x4000,True),[])
        self.assertIn('wrong_complete_value',oracle.step_errors(three,two,(0x3fff,1<<63),0x200,True))
        self.assertIn('wrong_complete_quotient',oracle.step_errors(three,two,(0xbfff,1<<63),0,True))

    def test_partial_and_negative_controls(self):
        a=(0x403f,5<<61);b=(0x3fff,1<<63)
        for condition in (0x400,0x4700):
            self.assertEqual(oracle.step_errors(a,b,(0,0),condition,False),[])
        self.assertIn('missing_partial_c2',oracle.step_errors(a,b,(0,0),0,False))
        self.assertIn('invalid_partial_value',oracle.step_errors(a,b,b,0x400,False))
        self.assertIn('unexpected_exception',oracle.step_errors(a,b,(0,0),0x420,False))

    def test_sign_and_precision(self):
        minus_three=(0xc000,3<<62);minus_two=(0xc000,1<<63)
        self.assertEqual(oracle.step_errors(minus_three,minus_two,(0xbfff,1<<63),0x200,False),[])
        self.assertEqual(oracle.step_errors(minus_three,minus_two,(0x3fff,1<<63),0x4000,True),[])
        a=(0x3fff,(1<<63)+1);b=(0x4000,1<<63)
        self.assertIn('wrong_complete_value',oracle.step_errors(a,b,(0x3fff,1<<63),0,False))

    def test_fixture_coverage(self):
        rows=oracle.cases()
        self.assertEqual(len(rows),7488)
        self.assertEqual({(r['cw']>>8)&3 for r in rows},{0,2,3})
        self.assertEqual({(r['cw']>>10)&3 for r in rows},{0,1,2,3})
        self.assertEqual({r['kind'] for r in rows},{0,1})
        gaps={oracle.exponent(r['a'])-oracle.exponent(r['b']) for r in rows}
        self.assertTrue({63,64,65,32760}<=gaps)


if __name__=='__main__':unittest.main()
