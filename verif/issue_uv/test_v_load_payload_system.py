"""Fixture/observer-preservation tests; native coverage is reported separately."""
import unittest

import run_v_load_payload_system as flow


class Fixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (flow.REPO/'verif/fe_pipe/prefix-ex-system.S').read_text()

    def test_distinct_data_and_byte_merge_inputs(self):
        outputs = [flow.fixture(self.source, *case) for case in flow.PATTERNS]
        self.assertEqual(len(set(outputs)), 8)
        for output in outputs:
            self.assertIn('movl $(0xa1b2c300+p*0x01020305),(0x3000+p*4)', output)
            self.assertIn('movl $0x5a69c3d2,%ebx', output)
            self.assertIn('movl %eax,%cr3', output)
            self.assertIn('orl $0x80000000,%eax', output)
        self.assertIn('movb 31(%eax),%bh', outputs[2])
        self.assertIn('movb 31(%edi),%bh', outputs[4])

    def test_only_immediate_cases_seed_full_window(self):
        for label, u, v in flow.PATTERNS:
            output = flow.fixture(self.source, label, u, v)
            if label.startswith('now-'):
                self.assertEqual(output.count('warm_u:\n'), 1)
                self.assertEqual(output.count('    jmp warm_u\n'), 2)
            else:
                self.assertNotIn('warm_u:', output)
            self.assertEqual(output.count('hot_load:\n'), 1)
            self.assertIn('hot_load:\n    '+v+'\n', output)
        with self.assertRaises(AssertionError):
            flow.fixture(self.source.replace('movl $7,%ebx', 'movl $8,%ebx'), *flow.PATTERNS[0])

    def test_complete_comparisons_and_native_observer_retained(self):
        derived = flow.derive()
        for required in (
            "assert [r['n'] for r in tr.records]==list(range(len(gold.records)))",
            "assert [r['pc'] for r in tr.records]==[r['pc'] for r in gold.records]",
            'compare.compare_func(gold,tr,False,0xffffffff,False,20,log,sys_both=True)==0',
            "assert both['control']==both['candidate']",
            "assert clocks['cycle']==clocks['cycle-func']",
            "assert immediate['cycle']==immediate['cycle-func']",
            'p=observed_call(', "result['fixture_only']=models['control']==models['candidate']",
            "if label in ('same-bank','split','word'): assert memory_v==0",
            "for latency in (0,7)", "for r in (0,1)",
        ):
            self.assertIn(required, derived)
        self.assertNotIn('.pop(', derived)


if __name__ == '__main__':
    unittest.main()
