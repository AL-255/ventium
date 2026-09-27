"""WRAP32 geometry and observable response-order negatives; no RTL jobs."""
import copy
import argparse
import json
from pathlib import Path
import unittest
from check_memory_geometry import check, cache_fill_words
from test_memory_geometry_qualification import fixture, MAPPING, PROFILE
from memory_geometry_proof import sha


class WrapTests(unittest.TestCase):
    def rows(self, offset=28):
        rows, spec, clocks = fixture()
        for row in rows:
            if row['type'] in ('axi_ar', 'axi_ar_offer') and not row['narrow']:
                row.update(address=0x8000+offset, burst=2)
        return rows, spec, clocks

    def test_all_start_words(self):
        for offset in range(0, 32, 4):
            rows, spec, clocks = self.rows(offset)
            self.assertEqual(check(rows, spec, MAPPING, PROFILE, clocks)['wrap32_fills'], 1)
            request = next(row for row in rows if row['type'] == 'axi_ar' and not row['narrow'])
            words = cache_fill_words(request)
            self.assertEqual(words, [0x8000+(offset+4*i)%32 for i in range(8)])
            self.assertEqual(sorted(words), list(range(0x8000, 0x8020, 4)))

    def test_illegal_geometry(self):
        for changes in (dict(size=1), dict(len=3), dict(address=0x801d), dict(burst=0),
                        dict(burst=3), dict(burst=1, address=0x801c), dict(address=1<<40)):
            with self.subTest(changes=changes):
                rows, spec, clocks = self.rows()
                for row in rows:
                    if row['type'] in ('axi_ar', 'axi_ar_offer') and not row['narrow']:
                        row.update(changes)
                with self.assertRaises(ValueError): check(rows, spec, MAPPING, PROFILE, clocks)

    def test_nc_remains_incr_only(self):
        rows, spec, clocks = self.rows()
        for row in rows:
            if row['type'] in ('axi_ar', 'axi_ar_offer') and row['narrow']:
                row['burst'] = 2
        with self.assertRaises(ValueError): check(rows, spec, MAPPING, PROFILE, clocks)

    def test_response_corruption(self):
        for change in ('swap', 'duplicate', 'missing', 'same-clock', 'wrong-id', 'rresp', 'last'):
            with self.subTest(change=change):
                rows, spec, clocks = self.rows()
                indexes = [i for i, row in enumerate(rows) if row['type'] == 'axi_r' and not row['narrow']]
                i, j = indexes[0:2]
                if change == 'swap': rows[i], rows[j] = rows[j], rows[i]
                elif change == 'duplicate': rows.insert(j, copy.deepcopy(rows[i]))
                elif change == 'missing': rows.pop(j)
                elif change == 'same-clock': rows[j]['cycle'] = rows[i]['cycle']
                elif change == 'wrong-id': rows[j]['id'] += 1
                elif change == 'rresp': rows[j]['resp'] = 2
                else: rows[j]['last'] = 1
                rows[-1]['records'] = len(rows)
                with self.assertRaises(ValueError): check(rows, spec, MAPPING, PROFILE, clocks)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.out is None:
        unittest.main(argv=['test_memory_geometry_wrap'])
    else:
        args.out.mkdir(parents=True, exist_ok=False)
        with (args.out / 'tests.log').open('x') as stream:
            result = unittest.TextTestRunner(stream=stream, verbosity=2).run(
                unittest.defaultTestLoader.loadTestsFromTestCase(WrapTests))
        with (args.out / 'receipt.json').open('x') as stream:
            json.dump(dict(host_only=True, success=result.wasSuccessful(), tests_run=result.testsRun,
                source_sha256={str(path): sha(path) for path in (Path(__file__),
                    Path(__file__).with_name('check_memory_geometry.py'),
                    Path(__file__).with_name('test_memory_geometry_qualification.py'))}), stream, indent=2)
        print((args.out / 'tests.log').read_text())
        raise SystemExit(not result.wasSuccessful())
