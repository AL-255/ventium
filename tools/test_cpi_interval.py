import unittest

from cpi_interval import samples, report, slow_samples, slow_report, umap_samples, umap_report


def profile(cycle, retires, count):
    return (f"[VEN-PERF] cycle={cycle} retires={retires} clocks={cycle} "
            f"u={retires} v=0 load_wait={count} store_wait=0 "
            f"state=0,{cycle} mem_wait=0,{count} mem_ack=0,{count} "
            f"bail=0,{count} alu_load=0,{2*count} alu_load_wait=0,{count} "
            f"alu_load_ack=0,{count}\n")


class IntervalTest(unittest.TestCase):
    def test_legacy_actual_bounds(self):
        log = [f"[{c:10}] retires={c // 4} cs=0008\n" for c in (0, 100, 200, 300)]
        a, b = samples(log, 51, 299)
        self.assertEqual((a['cycle'], b['cycle']), (100, 200))
        self.assertIn("CPI: 4.000000", report(a, b))

    def test_profile_precedence_and_overlap(self):
        log = ["[ 0] retires=0\n", profile(100, 20, 10),
               "[ 150] retires=30\n", profile(200, 40, 30)]
        a, b = samples(log)
        text = report(a, b)
        self.assertIn("IPC: 0.200000", text)
        self.assertIn("load_wait: 20 (20.00%", text)
        self.assertIn("mem_wait[1]: 20 (20.00%", text)
        self.assertIn("bail[1]: 20 (20.00%", text)
        self.assertIn("mem_ack[1]: 20\n", text)
        self.assertIn("Counter families overlap", text)

    def test_reset_rejected(self):
        with self.assertRaisesRegex(ValueError, "decreased"):
            samples([profile(100, 20, 10), profile(200, 30, 9)])

    def test_impossible_cumulative_profile(self):
        good = profile(100, 20, 10)
        for before, after in [('u=20', 'u=19'), ('u=20 v=0', 'u=5 v=15'),
                              ('state=0,100', 'state=0,99'),
                              ('mem_wait=0,10', 'mem_wait=0,95'),
                              ('alu_load_wait=0,10', 'alu_load_wait=0,11'),
                              ('load_wait=10', 'load_wait=11'),
                              ('u=20', 'u=-1'), ('cycle=100', 'cycle=99')]:
            with self.subTest(after=after), self.assertRaises(ValueError):
                samples([good.replace(before, after), profile(200, 40, 20)])

    def test_impossible_delta_even_when_cumulative_is_plausible(self):
        # ACK+wait fits each cumulative state, but not the new 100 clocks.
        a = profile(100,20,0)
        b = profile(200,40,10).replace('mem_wait=0,10', 'mem_wait=0,80').replace(
            'mem_ack=0,10', 'mem_ack=0,80')
        with self.assertRaisesRegex(ValueError, 'wait/ACK'):
            samples([a,b])

    def test_clock_epoch_discontinuity(self):
        a = profile(100,20,10).replace('cycle=100', 'cycle=110')
        b = profile(200,40,20).replace('cycle=200', 'cycle=211')
        with self.assertRaisesRegex(ValueError, 'simulation clocks'):
            samples([a,b])

    def test_unknown_counter_shape_duplicate_and_unsigned_range(self):
        bad = [profile(100,20,10).replace('mem_wait=0,10', 'mem_wait=10'),
               profile(100,20,10).rstrip()+' u=20\n',
               profile(100,20,10).replace('cycle=100',f'cycle={1<<64}')]
        for line in bad:
            with self.subTest(line=line), self.assertRaises(ValueError):
                samples([line,profile(200,40,20)])

    def test_diagnostic_prefix(self):
        a, b = samples([profile(100, 20, 10),
                        "tb: FLT vec=7 fault_pc=0002f" + profile(200, 40, 30)])
        self.assertEqual(b['cycle'], 200)
        self.assertIn("IPC: 0.200000", report(a, b))

    def test_prefixed_truncation_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            samples([profile(100, 20, 10),
                     "tb: FLT [VEN-PERF] cycle=200 retires=30\n"])

    def test_truncation_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            samples([profile(100, 20, 10), "[VEN-PERF] cycle=200 retires=30\n"])

    def test_one_sample_rejected(self):
        with self.assertRaisesRegex(ValueError, "two samples"):
            samples([profile(100, 20, 10)])

    def test_zero_retires(self):
        a, b = samples([profile(100, 0, 10), profile(200, 0, 20)])
        self.assertIn("CPI: undefined", report(a, b))
        self.assertIn("Secondary share of profiler retirements: undefined", report(a, b))

    def test_secondary_retirement_share(self):
        a, b = samples([profile(100, 20, 10),
                        profile(200, 40, 20).replace("u=40 v=0", "u=35 v=5")])
        text = report(a, b)
        self.assertIn("Primary retirement events: 15", text)
        self.assertIn("Secondary retirement events: 5", text)
        self.assertIn("Secondary share of profiler retirements: 25.00%", text)

    def test_shape_change_rejected(self):
        with self.assertRaisesRegex(ValueError, "family lengths"):
            samples([profile(100, 20, 10),
                     profile(200, 40, 20).replace("state=0,200", "state=200")])


def slow_line(cycle, count=0, prefixed=0):
    values = [0] * 513
    values[0x8a] = count
    values[256 + 0xb6] = count
    return f"[VEN-SLOW-DECODE] cycle={cycle} prefixed={prefixed} clocks=" + ','.join(map(str, values)) + '\n'


class SlowIntervalTest(unittest.TestCase):
    def test_interval_and_prefix(self):
        a, b = slow_samples([slow_line(0), slow_line(100, 10, 2),
                             'diagnostic ' + slow_line(200, 30, 5)], 50, 250)
        self.assertEqual((a['cycle'], b['cycle']), (100, 200))
        text = slow_report(a, b)
        self.assertIn('Slow-decode residency: 40 clocks', text)
        self.assertIn('Prefixed residency: 3 clocks', text)
        self.assertIn('0f b6: 20 (50.00%', text)
        self.assertIn('NOT instruction', text)

    def test_bad_samples(self):
        for line in ('[VEN-SLOW-DECODE] cycle=1\n',
                     '[VEN-SLOW-DECODE] cycle=1 prefixed=0 clocks=1,2\n',
                     slow_line(10, 1, 3)):
            with self.assertRaises(ValueError):
                slow_samples([line])

    def test_reset_and_impossible_delta(self):
        for lines in ([slow_line(100, 10), slow_line(200, 9)],
                      [slow_line(100), slow_line(101, 2)],
                      [slow_line(100, 10), slow_line(200, 10, 1)]):
            with self.assertRaises(ValueError):
                slow_samples(lines)

    def test_no_data_and_zero(self):
        for lines in ([], [slow_line(100)]):
            with self.assertRaises(ValueError):
                slow_samples(lines)
        self.assertIn('residency: 0 clocks', slow_report(*slow_samples([slow_line(100), slow_line(200)])))


def umap_line(cycle, n):
    return (f'[VEN-UMAP] cycle={cycle} raw={5*n} would_issue={n} '
            f'fp={n} nonsimple={n} simple_mem={n} fastctx={n} sysblock={n} '
            f'fastend=0,0,{n},0,0,0 would_issue_end=0,0,{n},0,0,0\n')


class UmapIntervalTest(unittest.TestCase):
    def test_actual_bounds_and_subsets(self):
        a, b = umap_samples([umap_line(0, 0), umap_line(100, 2),
                             'diagnostic ' + umap_line(200, 4)], 50, 250)
        text = umap_report(a, b)
        self.assertIn('100..200', text)
        self.assertIn('Resident map-hole clocks: 10', text)
        self.assertIn('would_issue: 2 (2.00%', text)
        self.assertIn('slot capacity: 2', text)
        self.assertIn('subset of fastctx', text)

    def test_schema_and_counts(self):
        for bad in ('[VEN-UMAP] cycle=1\n',
                    umap_line(100, 1).replace('raw=5', 'raw=4'),
                    umap_line(100, 1).replace('fastend=0,0,1,0,0,0', 'fastend=0,1'),
                    umap_line(100, 1).replace('would_issue=1', 'would_issue=2'),
                    umap_line(1, 1)):
            with self.assertRaises(ValueError):
                umap_samples([bad])

    def test_reset_and_impossible_interval(self):
        for lines in ([umap_line(100, 2), umap_line(200, 1)],
                      [umap_line(100, 2), umap_line(101, 3)]):
            with self.assertRaises(ValueError):
                umap_samples(lines)

    def test_missing_and_zero(self):
        for lines in ([], [umap_line(100, 1)]):
            with self.assertRaises(ValueError):
                umap_samples(lines)
        self.assertIn('clocks: 0', umap_report(*umap_samples([umap_line(100, 0), umap_line(200, 0)])))


if __name__ == '__main__':
    unittest.main()
