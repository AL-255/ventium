#!/usr/bin/env python3
"""Synthetic records test diagnostic equations; never produce a .vtrace."""
import copy
import unittest

from audit_preexit_gpr_flow import analyze


def fixture():
    codes = ('d9e8', 'dfe0', '0fb7c8', 'ddd8')
    g = [dict(n=n, pc=hex(0x1000+n*4), bytes=code,
              eax=hex(0x12340000 if n == 0 else 0x12342820),
              ecx=hex(0x98760000 if n < 2 else 0x2820), fstat='0x2820')
         for n, code in enumerate(codes)]
    r = copy.deepcopy(g)
    for n, row in enumerate(r):
        row['fstat'] = '0x2a20'
        if n: row['eax'] = '0x12342a20'
        if n >= 2: row['ecx'] = '0x2a20'
    return g, r


def differences(g, r):
    return [dict(n=n, field=f, expected=a[f], actual=b[f])
            for n, (a, b) in enumerate(zip(g, r)) for f in ('eax', 'ecx')
            if a[f] != b[f]]


class FlowTests(unittest.TestCase):
    def test_copy_zeroextend_and_preserve_full_registers(self):
        g, r = fixture()
        result = analyze(g, r, differences(g, r))
        self.assertEqual(len(result), 5)
        self.assertEqual([x['kind'] for x in result].count('FNSTSW_AX_from_prior_status'), 1)
        self.assertEqual([x['kind'] for x in result].count('MOVZX_ECX_AX'), 1)
        self.assertTrue(all(x['origin']['fsw_input_record'] == 0 for x in result))

    def test_status_after_store_is_not_used_as_its_input(self):
        g, r = fixture()
        g[1]['fstat'] = r[1]['fstat'] = '0x0000'
        self.assertEqual(len(analyze(g, r, differences(g, r))), 5)

    def test_common_mode_corruption_is_not_hidden_by_matching_xor(self):
        for field, n, message in [('eax', 1, 'FNSTSW'), ('ecx', 2, 'MOVZX'),
                                  ('eax', 3, 'preservation')]:
            with self.subTest(field=field, n=n):
                g, r = fixture()
                for rows in (g, r): rows[n][field] = hex(int(rows[n][field], 16) ^ 0x10000)
                with self.assertRaisesRegex(AssertionError, message):
                    analyze(g, r, differences(g, r))

    def test_missing_records_unknown_opcode_and_other_bits_fail(self):
        for mode in ('missing', 'unknown', 'other_bits', 'unreported'):
            with self.subTest(mode=mode):
                g, r = fixture()
                d = differences(g, r)
                if mode == 'missing': r.pop()
                if mode == 'unknown': g[3]['bytes'] = '90'
                if mode == 'other_bits': r[1]['eax'] = '0x12342b20'
                if mode == 'unreported': d.pop()
                with self.assertRaises(AssertionError): analyze(g, r, d)

    def test_equal_traces_are_not_evidence_of_a_dispute(self):
        g, r = fixture()
        with self.assertRaisesRegex(AssertionError, 'disappeared'):
            analyze(g, g, differences(g, r))


if __name__ == '__main__':
    unittest.main()
