"""Save-map and SMM-context witness discriminators, independent of native runs."""
import unittest
from run_bus_cancel_smm import SAVED, FLUSH, check_save, check_trace


class SmmContracts(unittest.TestCase):
    def test_save_map_checks_each_required_slot(self):
        values = dict(SAVED, save_cr0=0x11, save_eip=0xf0000, save_dr6=0xffff0ff0)
        good = {key: hex(value) for key, value in values.items()}
        check_save(good)
        for key in SAVED:
            with self.subTest(slot=key), self.assertRaises(AssertionError):
                check_save(dict(good, **{key: hex(values[key] ^ 1)}))
        for key, bad in (('save_cr0', 0x10), ('save_eip', 0xe0000), ('save_dr6', 0)):
            with self.subTest(slot=key), self.assertRaises(AssertionError):
                check_save(dict(good, **{key: hex(bad)}))

    def test_smm_entry_and_restore_are_not_vacuous(self):
        main = dict(cs='0x8', cr0='0x11', pc='0xf0000', ebx='0x5a4d900d')
        entry = dict(main, cs='0x3000', cr0='0x10', pc='0x8000')
        records = [main]*150+[entry]+[main]*151
        check_trace('psmm', records)
        for bad in ([main]*302, records+[entry],
                    [main]*150+[entry]+[dict(main, ebx='0')]*151):
            with self.assertRaises(AssertionError):
                check_trace('psmm', bad)

    def test_resumed_mapping_requires_both_smm_rounds_and_new_stub(self):
        main = dict(cs='0x8', cr0='0x80000011', pc='0xf0000', ebx='0x5a4d900d')
        entry = dict(main, cs='0x3000', cr0='0x10', pc='0x8000')
        final = dict(main, **{key: hex(value) for key, value in FLUSH.items()}, edx='0x600d00f4')
        good = [main]*150+[entry, main, entry]+[main]*151+[final]
        check_trace('prsmflush_smm', good)
        with self.assertRaises(AssertionError):
            check_trace('prsmflush_smm', good[:-1]+[dict(final, edi='0x5a4d0001')])


if __name__ == '__main__':
    unittest.main()
