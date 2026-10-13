"""Source-contract tests for a retry witness; not processor acceptance."""
import ast
from pathlib import Path
import unittest

import prepare_retry as fixture
import run_retry as runner
import run_retry_mutants as mutants


class Retry(unittest.TestCase):
    def test_pre_repair_checks_unchanged(self):
        source=(Path(__file__).with_name('fault.S')).read_text()
        new=fixture.transform(source)
        old_handler=source[source.index('fault_handler:\n'):source.index('success:\n')]
        self.assertEqual(new[new.index('fault_handler:\n'):new.index(fixture.REPAIR)],old_handler)
        self.assertEqual(new.count('    iretl\n'),1)
        self.assertIn('    iretl\n    jmp fail\n',new)
        for marker in ('cmpl $0x8fdc, %esp','movl 32(%esp), %eax',
                       'cmpl $0x001ba5a5, %es:ALIAS+0xffd','cmpl $0xa5a5a500, %es:ALIAS+0x1000'):
            self.assertIn(marker,new.split('smsw_after:\n')[1].split('ud_handler:\n')[0])

    def test_drift_and_double_application_rejected(self):
        source=(Path(__file__).with_name('fault.S')).read_text()
        for bad in (source+'\n',fixture.transform(source)):
            with self.assertRaises(ValueError):fixture.transform(bad)

    def test_native_compare_and_fault_contract_retained(self):
        original=runner.original.read_text()
        for start,end in (("        native = run('qemu-native'",'        save(folder/'),
                          ('    with concurrent.futures.ThreadPoolExecutor','    result.update')):
            self.assertEqual(original.split(start)[1].split(end)[0],runner.text.split(start)[1].split(end)[0])
        self.assertEqual(runner.text.count('range(4,9)'),2)
        self.assertIn("len(result['rows'])==25",runner.text)
        self.assertIn("AXI_RLAT=str(args.latency),AXI_WLAT=str(args.latency)",runner.text)
        ast.parse(runner.text)

    def test_mutant_driver_preserves_template_pin_without_local_collision(self):
        self.assertIn("(Path(__file__),template,HERE/'run_probe.py',args.audit,model)",mutants.text)
        self.assertIn("original=fault/name/'probe.bin'",mutants.text)
        self.assertIn("assert len(jobs)==85",mutants.text)
        self.assertIn("('no-iret',data[:offset]+bytes([0x90])+data[offset+1:])",mutants.text)
        ast.parse(mutants.text)


if __name__=='__main__':unittest.main()
