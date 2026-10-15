import struct
import unittest
import partial_underflow_vectors as vectors


class Partial(unittest.TestCase):
    def test_all_legal_steps_tiny_and_mask_priority(self):
        rows = vectors.rows(); counts = [0,0,0]
        for row in rows:
            e = vectors.expected(row)
            counts[0 if e['underflow'] else 1 if e['abort'] else 2] += 1
            self.assertGreaterEqual(e['gap'],64)
            self.assertTrue(e['values'])
            for value in e['values']:
                raw = bytearray(108); top=(row['sw']>>11)&7
                tag=(row['tag']&~(3<<(2*top)))|(vectors.state.tag(value)<<(2*top))
                struct.pack_into('<3I',raw,0,row['cw'],e['status'],tag)
                values=[value,row['b'],*[(0x4000+((255+i)&255),1<<63) for i in range(2,8)]]
                for i,v in enumerate(values): struct.pack_into('<QH',raw,28+10*i,v[1],v[0])
                self.assertEqual(vectors.check(row,raw),[])
            if e['underflow']:
                raw[4] ^= 16
                self.assertIn('status',vectors.check(row,raw))
        self.assertEqual(counts,[720,1440,720])


if __name__ == '__main__': unittest.main()
