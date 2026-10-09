import copy
from pathlib import Path
import re
import unittest
from ven_total_retire import SELECTOR, DATA, CAPABILITY
import ven_ipc_window as ipc


class Board:
    def __init__(self):
        self.cycles = 100
        self.total = 40
        self.selector = 12
        self.writes = []
        self.words = {ipc.CONTROL: 0x102, ipc.EXEC_CONTROL: 0,
                      ipc.EXEC_CAPABILITY: 0x56450005, ipc.FREEZE_INFO: 0}
        self.capability = CAPABILITY

    def advance(self):
        self.cycles += 1
        self.total += 2

    def read(self, offset):
        self.advance()
        if offset in self.words: return self.words[offset]
        if offset == ipc.CYCLE_LO: return self.cycles & 0xffffffff
        if offset == ipc.CYCLE_HI: return self.cycles >> 32
        if offset == SELECTOR: return self.selector
        assert offset == DATA
        if self.selector == 78: return self.capability
        if self.selector == 76: return self.total & 0xffffffff
        assert self.selector == 77
        return self.total >> 32

    def write(self, offset, value):
        assert offset == SELECTOR
        self.advance()
        self.selector = value
        self.writes.append((offset, value))

    def sample(self, **kwargs): return ipc.sample(self.read, self.write, **kwargs)


def endpoint(lo, hi, count):
    return dict(counter_kind=ipc.COUNTER_KIND, cycles_before=lo, cycles_after=hi,
                total_retirements=count, span_cycles=hi-lo)


class IPCWindowTests(unittest.TestCase):
    def test_register_contract(self):
        body=(Path(__file__).with_name('ven_board_probe.py')).read_text()
        for name,value in [('R_DBG_CYC_LO',ipc.CYCLE_LO),('R_DBG_CYC_HI',ipc.CYCLE_HI),
                           ('R_DBG_EXEC_CTRL',ipc.EXEC_CONTROL),('R_DBG_EXEC_CAP',ipc.EXEC_CAPABILITY),
                           ('R_DBG_FRZINFO',ipc.FREEZE_INFO)]:
            self.assertEqual(int(re.search(r'^'+name+r' = (0x[0-9a-fA-F]+)',body,re.M)[1],16),value)

    def test_live_brackets_and_only_selector_writes(self):
        b=Board(); first=b.sample(); b.cycles+=40000000; b.total+=20000000; last=b.sample()
        result=ipc.interval(first,last)
        self.assertLess(result['ipc_lower_bound'],result['ipc_estimate'])
        self.assertLess(result['ipc_estimate'],result['ipc_upper_bound'])
        self.assertAlmostEqual(result['ipc_estimate'],0.5,places=5)
        self.assertEqual(b.selector,12)
        self.assertTrue(all(a==SELECTOR for a,_ in b.writes))
        self.assertFalse(result['gameplay_qualified'])
        self.assertFalse(result['uv_fast_history_qualified'])

    def test_refuse_inactive_or_unknown_execution_modes(self):
        for address,values in [(ipc.CONTROL,[0,1,2,0x101]),(ipc.EXEC_CONTROL,[1,2,4,8,0x100]),
                               (ipc.EXEC_CAPABILITY,[0,0x56450004]),(ipc.FREEZE_INFO,[0x80000000])]:
            for value in values:
                with self.subTest(address=address,value=value):
                    b=Board(); b.words[address]=value
                    with self.assertRaises(ValueError): b.sample()
                    self.assertFalse(b.writes)

    def test_unsupported_total_counter(self):
        b=Board(); b.capability=0
        with self.assertRaisesRegex(RuntimeError,'UV64'): b.sample()
        self.assertEqual(b.selector,12)

    def test_reserved_selector_and_bad_callback_values(self):
        b=Board(); b.selector=128
        with self.assertRaises(ValueError): b.sample()
        self.assertFalse(b.writes)
        for value in [True,-1,1<<32,1.5]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                ipc.sample(lambda _:value,lambda *_:self.fail('unexpected write'))

    def test_excessive_span_and_bad_limit(self):
        b=Board()
        with self.assertRaisesRegex(ValueError,'span'): b.sample(max_span_cycles=1)
        self.assertEqual(b.selector,12)
        for value in [True,0,-1,1.0]:
            with self.subTest(value=value), self.assertRaises(ValueError): b.sample(max_span_cycles=value)

    def test_clock_unstable_is_bounded(self):
        b=Board(); high_reads=0
        def read(address):
            nonlocal high_reads
            if address==ipc.CYCLE_HI:
                high_reads+=1
                return high_reads
            return b.read(address)
        with self.assertRaisesRegex(ValueError,'stable'): ipc.sample(read,b.write)
        self.assertEqual(high_reads,16)
        self.assertFalse(b.writes)

    def test_clock_low_word_rollover_retries(self):
        b=Board(); b.cycles=(1<<32)-7
        result=b.sample()
        self.assertGreaterEqual(result['cycles_before'],1<<32)
        self.assertLess(result['cycles_after']-result['cycles_before'],100)
        self.assertEqual(b.selector,12)

    def test_clock_reset_during_sample(self):
        b=Board(); low_reads=0
        def read(address):
            nonlocal low_reads
            if address==ipc.CYCLE_LO:
                low_reads+=1
                if low_reads==2:b.cycles=0
            return b.read(address)
        with self.assertRaisesRegex(ValueError,'reset'): ipc.sample(read,b.write)
        self.assertEqual(b.selector,12)

    def test_halt_after_counter_read(self):
        b=Board(); control_reads=0
        def read(address):
            nonlocal control_reads
            if address==ipc.CONTROL:
                control_reads+=1
                if control_reads==2:return 1
            return b.read(address)
        with self.assertRaises(ValueError): ipc.sample(read,b.write)
        self.assertEqual(b.selector,12)

    def test_bounds_at_strict_target(self):
        result=ipc.interval(endpoint(100,110,1000),endpoint(1100,1110,1480))
        self.assertEqual(result['ipc_estimate'],0.48)
        self.assertLess(result['ipc_lower_bound'],0.48)
        self.assertGreater(result['ipc_upper_bound'],0.48)

    def test_real_zero_retirement_is_not_dropped(self):
        result=ipc.interval(endpoint(100,110,1000),endpoint(1100,1110,1000))
        self.assertEqual(result['retired'],0)
        self.assertEqual(result['ipc_estimate'],0)

    def test_reset_overlap_and_impossible_rate(self):
        a=endpoint(100,110,1000)
        for b in [endpoint(1100,1110,999),endpoint(0,10,2000),endpoint(105,115,1001),
                  endpoint(1100,1110,4000),endpoint(110,120,1001)]:
            with self.subTest(after=b), self.assertRaises(ValueError): ipc.interval(a,b)

    def test_wrong_counter_and_malformed_records(self):
        a=endpoint(100,110,1000); b=endpoint(1100,1110,1500)
        for key,value in [('counter_kind','primary'),('cycles_before',True),
                          ('total_retirements',-1),('cycles_after',1<<64),('span_cycles',9),('span_cycles',10.0)]:
            bad=copy.deepcopy(a);bad[key]=value
            with self.subTest(key=key), self.assertRaises(ValueError): ipc.interval(bad,b)

    def test_large_u64_absolute_times_preserve_small_deltas(self):
        offset=(1<<64)-10000
        a=endpoint(offset+100,offset+110,offset+1000)
        b=endpoint(offset+1100,offset+1110,offset+1480)
        self.assertEqual(ipc.interval(a,b)['ipc_estimate'],0.48)


if __name__=='__main__': unittest.main()
