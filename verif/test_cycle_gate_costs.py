"""Cost attribution must conserve all clocks, not turn warm subsets into PASS."""
from copy import deepcopy
import unittest

from analyze_cycle_gate_costs import summarize


class CycleCosts(unittest.TestCase):
    def setUp(self):
        self.a = [dict(n=n, pc=pc, cyc=cyc) for n,(pc,cyc) in enumerate(
            [('0x1000',9), ('0x1001',10), ('0x1000',11), ('0x1001',12)])]
        self.c = [dict(n=n, pc=pc, cyc=cyc, pipe=pipe) for n,(pc,cyc,pipe) in enumerate(
            [('0x1000',74,'U'), ('0x1001',74,'V'),
             ('0x1000',75,'U'), ('0x1001',75,'V')])]

    def test_complete_partition_and_same_clock_v(self):
        result = summarize(self.a, self.c)
        self.assertEqual(result['excess_clocks'], 63)
        self.assertEqual(result['buckets']['first_pc']['excess_clocks'], 64)
        self.assertEqual(result['buckets']['revisited_pc']['excess_clocks'], -1)
        self.assertEqual(sum(b['rtl_clocks'] for b in result['buckets'].values()), 75)
        self.assertEqual(sum(b['v_records'] for b in result['buckets'].values()), 2)
        self.assertNotIn('passed', result)

    def test_no_truncation_or_reordering(self):
        for bad in ([], self.c[:-1], list(reversed(self.c))):
            with self.assertRaises(ValueError): summarize(self.a, bad)
        for key,value in (('pc','0x1002'),('n',9)):
            bad=deepcopy(self.c); bad[1][key]=value
            with self.assertRaises(ValueError): summarize(self.a,bad)

    def test_no_counter_repair(self):
        for value in (0, 1.5, True, '74'):
            bad=deepcopy(self.c);bad[2]['cyc']=value
            with self.assertRaises(ValueError): summarize(self.a,bad)

    def test_warm_penalty_is_retained(self):
        bad=deepcopy(self.c);bad[2]['cyc']+=10;bad[3]['cyc']+=10
        result=summarize(self.a,bad)
        self.assertEqual(result['excess_clocks'],73)
        self.assertEqual(result['buckets']['revisited_pc']['excess_clocks'],9)

    def test_unrolled_stream_has_no_revisited_bucket(self):
        result=summarize(self.a[:2],self.c[:2])
        self.assertEqual(result['records'],2)
        self.assertEqual(result['buckets']['revisited_pc'].get('records',0),0)
        self.assertEqual(result['buckets']['first_pc']['rtl_clocks'],74)

    def test_revisited_pc_is_not_claimed_to_be_a_cache_hit(self):
        bad=deepcopy(self.c)
        bad[2]['cyc']=1075;bad[3]['cyc']=1075
        result=summarize(self.a,bad)
        self.assertEqual(result['buckets']['revisited_pc']['rtl_clocks'],1001)
        self.assertEqual(result['excess_clocks'],1063)
        self.assertNotIn('cache_hits',result)


if __name__ == '__main__': unittest.main()
