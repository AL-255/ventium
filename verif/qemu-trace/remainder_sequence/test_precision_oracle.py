import struct
import unittest

import precision_oracle as oracle


class Precision(unittest.TestCase):
    def test_known_values(self):
        rows=oracle.cases()
        self.assertEqual(len(rows),96)
        for row in rows:
            value,pe,c1=oracle.expected(row)
            self.assertEqual(value[0],0x4000|(row['sign']<<15))
            exact=(3<<62)+(1<<row['bit'])
            if row['bits']==64 or row['bits']==53 and row['bit']==32:
                self.assertEqual((value[1],pe,c1),(exact,False,False))
            else:
                rounded_up=row['rc']==1 and row['sign'] or row['rc']==2 and not row['sign']
                self.assertEqual(value[1],(3<<62)+((1<<(64-row['bits'])) if rounded_up else 0))
                self.assertEqual((pe,c1),(True,bool(rounded_up)))

    def test_leaking_pc_rejected(self):
        row=oracle.cases()[0]
        value,pe,c1=oracle.expected(row)
        def output(sum_value,status):
            return struct.pack('<I4HQHQH',0,row['cw'],row['sw'],status,0,
                row['a'][1],row['a'][0],sum_value,value[0])
        self.assertTrue(oracle.grade([row],output(value[1],row['sw']|(int(pe)<<5)|(int(c1)<<9)))['passed'])
        bad=oracle.grade([row],output((3<<62)+(1<<row['bit']),row['sw']))
        self.assertFalse(bad['passed'])
        self.assertIn('precision_not_restored',bad['errors'][0]['reasons'])
        self.assertIn('wrong_add_status',bad['errors'][0]['reasons'])


if __name__=='__main__':unittest.main()
