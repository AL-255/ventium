"""Closure-grader negatives, independent of any RTL performance result."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('payload_driver',
    Path(__file__).with_name('run-fp-payload-ab.py'))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
fmt = driver.tracefmt


class NativeX87Closure(unittest.TestCase):
    def setUp(self):
        row = fmt.func_record(0, 0x1000, 2,
            {k: 0 for k in fmt.GPR_KEYS}, {k: 0 for k in fmt.SEG_KEYS},
            x87={k: 0 for k in fmt.X87_REGS + fmt.X87_CTL},
            sysregs={k: 0 for k in fmt.SYS_CR})
        self.trace = fmt.Trace(fmt.header('rtl', 'func', x87=True, sys=True), [row])
        self.err = ('tb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) '
                    'after 1 retired in 10 clocks\n'
                    'tb: retired 1 instructions in 10 clocks (bus: 0 reads, 0 writes)\n'
                    'tb: M7.3b win95 co-sim: 0 IN reads serviced '
                    '(0 dev_in available, cursor at 0), 1 OUT writes consumed, '
                    '0 port/size desync(s), isa-debug-exit reached\n')

    def grade(self, trace=None, err=None, exit_code=133):
        return driver.grade_fp_native(self.trace if trace is None else trace, '',
            self.err if err is None else err, exit_code, 133, 100)

    def test_complete_x87_closure(self):
        self.assertEqual(self.grade()['records'], 1)

    def test_missing_each_architectural_field(self):
        for key in fmt.func_compare_keys(True, True):
            altered = copy.deepcopy(self.trace)
            del altered.records[0][key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.grade(altered)

    def test_bad_x87_value_and_headers(self):
        for value in (-1, 1 << 80, True, None):
            altered = copy.deepcopy(self.trace)
            altered.records[0]['st0'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.grade(altered)
        for key, value in [('x87', False), ('sys', False), ('mode', 'cycle')]:
            altered = copy.deepcopy(self.trace)
            altered.hdr[key] = value
            with self.subTest(header=key), self.assertRaises(ValueError):
                self.grade(altered)

    def test_native_failure_and_incomplete_footer(self):
        for code in (0, -15, 124):
            with self.subTest(code=code), self.assertRaises(ValueError):
                self.grade(exit_code=code)
        for err in ('', self.err.rstrip(), self.err + self.err,
                    self.err.replace('after 1 retired', 'after 2 retired'),
                    self.err.replace('0 port/size desync', '1 port/size desync')):
            with self.subTest(stderr=err), self.assertRaises(ValueError):
                self.grade(err=err)


if __name__ == '__main__':
    unittest.main()
