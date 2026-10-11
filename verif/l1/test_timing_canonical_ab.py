import unittest
from types import SimpleNamespace
from audit_timing_canonical_ab import require_identical


class CanonicalRecords(unittest.TestCase):
    def trace(self,rows,**overrides):
        return SimpleNamespace(**(dict(mode='func',sys=False,x87=True,records=rows)|overrides))

    def test_identical(self):
        require_identical(self.trace([{'n':0,'fsw':'0x0200'}]),self.trace([{'n':0,'fsw':'0x0200'}]))

    def test_c1_terminal_and_mode_differences_rejected(self):
        original=self.trace([{'n':0,'fsw':'0x0200'}])
        for changed in (self.trace([{'n':0,'fsw':'0x0000'}]),self.trace([]),
                        self.trace([{'n':0,'fsw':'0x0200'}],x87=False)):
            with self.assertRaises(AssertionError):
                require_identical(original,changed)

    def test_initial_stack_is_not_normalized(self):
        with self.assertRaises(AssertionError):
            require_identical(self.trace([{'n':0,'esp':'0x408000f0'}]),
                              self.trace([{'n':0,'esp':'0x408000c0'}]))


if __name__=='__main__':
    unittest.main()
