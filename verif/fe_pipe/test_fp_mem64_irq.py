#!/usr/bin/env python3
"""IRQ fixture drift and precise separation of event-entry ABI records."""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE/filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


generator = module('irq_fixture','prepare-fp-mem64-irq.py')
driver = module('irq_driver','run-fp-mem64-irq.py')


class WideQueueIrq(unittest.TestCase):
    def test_fixture(self):
        source = (HERE/'fp-mem64-queue.S').read_text()
        text = generator.transform(source)
        for expected in ('irq_boundary:\n', '    sti\n', '0x1228',
                         'cmpl $irq_boundary,32(%esp)', 'cmpl $source_op,0x8f24c'):
            self.assertIn(expected, text)
        self.assertNotIn('    int3\n', text)
        self.assertIn('#error IRQ oracle requires flat CS and external events', text)
        self.assertEqual((HERE/'fp-mem64-queue.S').read_text(), source)
        for wrong in ('', source+source, text):
            with self.assertRaises(ValueError):
                generator.transform(wrong)

    def test_entry_records_are_compared_not_lost(self):
        rows = []
        for _ in range(16):
            # The resumed real boundary instruction must remain in the stream.
            for pc in (0x100,0x101,0x200,0x220,0x101,0x104):
                rows.append(dict(n=len(rows),pc=hex(pc),eax=hex(len(rows))))
        trace = driver.tracefmt.Trace({}, rows)
        entries, instructions = driver.split_entries(trace,0x100,0x101,0x200)
        self.assertEqual(len(entries.records),16)
        self.assertEqual(len(instructions.records),80)
        self.assertEqual(sum(int(r['pc'],0)==0x101 for r in instructions.records),16)
        self.assertEqual({r['eax'] for r in entries.records}|{r['eax'] for r in instructions.records},
                         {r['eax'] for r in rows})
        for bad in (rows[:-6],rows+rows[:6],[] ):
            with self.assertRaises(AssertionError):
                driver.split_entries(driver.tracefmt.Trace({},bad),0x100,0x101,0x200)


if __name__=='__main__':
    unittest.main()
