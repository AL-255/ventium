import unittest

import ven_quake_ipc as quake
from test_ven_ipc_window import Board, endpoint as counters


def engine(frame=33):
    return dict(available=True, demo_active=1, demo_file=17,
                host_framecount=frame, td_startframe=0)


def record(clock, retired, frame=33):
    return dict(engine_before=engine(frame), engine_after=engine(frame),
                counters=counters(clock, clock+10, retired))


class Memory:
    def __init__(self):
        self.words = {}
        self.reads = []
        self.pde = quake.PAGE_DIRECTORY + (quake.DATA_BASE >> 22)*4
        self.words[self.pde] = 0x80003
        for index, (name, offset) in enumerate(quake.FIELDS):
            self.words[0x80000 + ((offset >> 12) & 1023)*4] = (0x100000 + (offset & ~4095)) | 3
            self.words[0x100000 + offset] = engine()[name]

    def read(self, address):
        if address & 3 or not 0 <= address < quake.RAM_BYTES:
            raise AssertionError('out-of-range callback')
        self.reads.append(address)
        return self.words.get(address, 0)


class QuakeIPCTests(unittest.TestCase):
    def test_scalar_paged_fields(self):
        mem = Memory()
        self.assertEqual(quake.engine_status(mem.read), engine())
        self.assertEqual(len(mem.reads), 40)

    def test_bad_page_tables_never_escape_ram(self):
        for pde, pte in [(0, 3), (0x80083, 3), (0xfffff003, 3), (0x80003, 0),
                         (0x80003, 0xfffff003)]:
            mem = Memory(); mem.words[mem.pde] = pde
            for _, offset in quake.FIELDS:
                mem.words[0x80000+((offset>>12)&1023)*4] = pte
            with self.subTest(pde=pde, pte=pte):
                self.assertFalse(quake.engine_status(mem.read)['available'])

    def test_mapping_change_refuses_sample(self):
        mem = Memory(); seen = 0
        def read(address):
            nonlocal seen
            if address == mem.pde:
                seen += 1
                if seen == 2: return 0x81003
            return mem.read(address)
        self.assertIn('mapping changed', quake.engine_status(read)['reason'])

    def test_changing_fields_and_io_errors(self):
        mem = Memory(); seen = 0
        def read(address):
            nonlocal seen
            if address == 0x100000 + quake.FIELDS[2][1]:
                seen += 1
                return 33 + seen
            return mem.read(address)
        self.assertIn('fields changed', quake.engine_status(read)['reason'])
        def broken(_): raise OSError('physical I/O failed')
        with self.assertRaises(OSError): quake.engine_status(broken)

    def test_endpoint_only_writes_selector(self):
        board = Board(); mem = Memory()
        point = quake.endpoint(board.read, board.write, mem.read)
        self.assertEqual(point['engine_before'], point['engine_after'])
        self.assertTrue(board.writes)
        self.assertTrue(all(address == 0x2a0 for address, _ in board.writes))
        self.assertEqual(board.selector, 12)

    def test_equal_frames_zero_retirement_and_zero_start_are_kept(self):
        result = quake.interval(record(100, 1000), record(1100, 1000))
        self.assertTrue(result['membership_observed'])
        self.assertEqual(result['ipc_estimate'], 0)
        self.assertFalse(result['gameplay_qualified'])

    def test_fixed_frame_boundaries(self):
        for first, last, expected in [(32,33,False),(33,33,True),(899,900,True),
                                      (900,901,False),(34,33,False)]:
            with self.subTest(first=first, last=last):
                result = quake.interval(record(100,1000,first), record(1100,1400,last))
                self.assertEqual(result['membership_observed'], expected)

    def test_identity_inactive_and_torn_witness_refused(self):
        for key, value in [('demo_file',18),('td_startframe',1),('demo_active',0),
                           ('host_framecount', True),('available',False)]:
            point = record(1100,1400,34)
            point['engine_before'][key] = point['engine_after'][key] = value
            with self.subTest(key=key):
                self.assertFalse(quake.interval(record(100,1000),point)['membership_observed'])
        point = record(1100,1400,34);point['engine_after']['host_framecount'] = 35
        self.assertFalse(quake.interval(record(100,1000),point)['membership_observed'])

    def test_counter_failure_outside_gameplay_is_still_fatal(self):
        with self.assertRaisesRegex(ValueError, 'reset'):
            quake.interval(record(100,1000,0),record(1100,999,1))

    def test_weighted_score_not_mean_and_keeps_slow_intervals(self):
        acc = quake.Accumulator()
        for item in [record(100,1000),record(1100,1500,34),record(101100,1500,34)]:
            acc.add(item)
        result = acc.result()
        self.assertEqual(result['included_intervals'],2)
        self.assertEqual(result['retired'],500)
        self.assertAlmostEqual(result['ipc_estimate'],500/101000)
        self.assertLess(result['ipc_lower_bound'],result['ipc_estimate'])
        self.assertFalse(result['target_pass'])

    def test_never_bridge_invalid_endpoints(self):
        acc = quake.Accumulator()
        points = [record(100,1000),record(1100,1400,34),record(2100,1800,35),
                  record(3100,2200,36),record(4100,2600,37)]
        points[2]['engine_before'] = dict(available=False, reason='mapping unavailable')
        for point in points: acc.add(point)
        result = acc.result()
        self.assertEqual(result['included_intervals'],2)
        self.assertEqual(sum(result['excluded_intervals'].values()),2)
        self.assertEqual(result['retired'],800)
        self.assertEqual(result['first'],dict(cycles=100,frame=33))
        self.assertEqual(result['last'],dict(cycles=4110,frame=37))

    def test_empty_and_pre_gameplay_are_not_zero_score(self):
        acc = quake.Accumulator()
        self.assertIsNone(acc.result()['ipc_estimate'])
        acc.add(record(100,1000,0)); acc.add(record(1100,1200,1))
        self.assertIsNone(acc.result()['ipc_estimate'])
        self.assertEqual(acc.result()['included_intervals'],0)


if __name__ == '__main__': unittest.main()
