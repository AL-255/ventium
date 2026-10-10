import unittest
from test_ic_prefix_board_profile import check_native_command


class NativeCommand(unittest.TestCase):
    def setUp(self):
        self.compiler='/tools/verilator/v5.046/bin/verilator'
        self.args=['+define+VEN_IC_PREFIX_SPAN','--assert','-CFLAGS',
                   '-std=c++17 -DVEN_BOARD_POSTED_PROFILE=1 -DVEN_BOARD_WRITE_SLOTS=16',
                   '-DVEN_CORE','-GBOARD_POSTED=1','core.sv']
        self.launch=['scope','--',self.compiler]+self.args
        self.record='C "'+' '.join(self.args)+'"\nT unrelated\n'

    def test_complete_command_and_host_macros(self):
        check_native_command(self.record,self.launch)

    def test_native_drift_rejected(self):
        variants=[self.record.replace('VEN_CORE','VEN_OTHER'),
                  self.record.replace('WRITE_SLOTS=16','WRITE_SLOTS=2'),
                  self.record.replace('--assert ',''),
                  self.record.replace('core.sv','stale-core.sv'),
                  self.record+self.record, 'T no command\n']
        for record in variants:
            with self.subTest(record=record),self.assertRaises(AssertionError):
                check_native_command(record,self.launch)

    def test_ambiguous_or_missing_compiler(self):
        for command in (self.args,self.launch+[self.compiler]):
            with self.subTest(command=command),self.assertRaises(AssertionError):
                check_native_command(self.record,command)


if __name__=='__main__':unittest.main()
