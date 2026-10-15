import unittest

from run_fetch_fragment_finite_cs import CASES, DATA, MODELS, check_trace_shape, model_definitions, pair_witness, parse_cmdline, precise_gp, require_backend_activity, tracefmt


class Checks(unittest.TestCase):
    def test_original_eight_cases_not_filtered(self):
        self.assertEqual(len(CASES), 8)
        for reloc in (0, 1):
            for offset in (4080, 4093, 4094, 4095):
                self.assertIn(f'k2-r{reloc}-o{offset}', CASES)

    def test_fault_count_class_and_restart_eip_are_exact(self):
        row = '[FAULT] vec=13 err=00000000 pc=0002fffd state=1 v86=0 depth=0\n'
        precise_gp(row, 0x2fffd)
        for invalid in ('', row+row, row.replace('vec=13', 'vec=14'),
                        row.replace('err=00000000', 'err=00000001'),
                        row.replace('pc=0002fffd', 'pc=00030001')):
            with self.assertRaises((ValueError, AssertionError)):
                precise_gp(invalid, 0x2fffd)

    def test_partial_native_argv_is_not_admitted(self):
        self.assertEqual(parse_cmdline(b'/a\0--cycle\0'), ['/a', '--cycle'])
        for value in (b'', b'/a\0--cycl'):
            with self.assertRaises(AssertionError): parse_cmdline(value)

    def test_actual_model_profiles_and_unexpected_duplicates(self):
        profiles = []
        for name, _ in MODELS.values():
            stamp = DATA/name/'obj/Vventium_top__verFiles.dat'
            command = next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
            profiles.append(model_definitions(command))
            with self.assertRaises(AssertionError): model_definitions(command+' +define+VEN_FE_PIPE')
            with self.assertRaises(AssertionError): model_definitions(command.replace(' --assert ', ' '))
        self.assertEqual(profiles[0], profiles[1])

    def test_backend_requires_transactions_not_optional_quiesce_banner(self):
        require_backend_activity('[L1DPERF] fill cycles=1341 backing-wait=798 backing-ack=543\n')
        for text in ('', 'tb: --l1-axi selected default --quiesce=4096\n',
                     '[L1DPERF] fill cycles=1341 backing-wait=798 backing-ack=0\n'):
            with self.assertRaises(AssertionError): require_backend_activity(text)

    def test_actual_functional_and_cycle_trace_contracts_are_distinct(self):
        root = DATA/'fetch-fragment-finite-cs-r3/k2-r0-o4093'
        for mode, wrong in (('cycle-func', 'cycle'), ('cycle', 'cycle-func')):
            trace = tracefmt.read_trace(str(root/('parent-lat0-'+mode+'.vtrace')))
            check_trace_shape(trace, mode)
            with self.assertRaises(AssertionError): check_trace_shape(trace, wrong)

    def test_pairing_is_dynamic_not_prescribed_by_assembly_label(self):
        root = DATA/'fetch-fragment-finite-cs-r4/k2-r0-o4093'
        rows = tracefmt.read_trace(str(root/'parent-lat0-cycle.vtrace')).records
        symbols = dict(pair_u=0xf02b0, pair_v=0xf02b5)
        self.assertTrue(pair_witness(rows, symbols))
        unpaired = [dict(row, paired=False) for row in rows]
        with self.assertRaises(AssertionError): pair_witness(unpaired, symbols)
        broken = [dict(row) for row in rows]
        v = next(row for row in broken if row['pipe'] == 'V')
        v['cyc'] += 1
        with self.assertRaises(AssertionError): pair_witness(broken, symbols)


if __name__ == '__main__': unittest.main()
