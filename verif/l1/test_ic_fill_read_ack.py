"""Source-contract checks only; native proof is a separate guarded run."""
import os
import copy
from pathlib import Path
import unittest

import prepare_ic_fill_read_ack as recipe
from run_ic_fill_read_ack_leaf import source_text
from build_ic_fill_read_ack_core import check_leaf


class Tests(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ['IC_FILL_PARENT'])
        self.core = (root/'rtl/core/core.sv').read_text()
        self.bus = (root/'rtl/core/core_bus_driver.svh').read_text()

    def test_only_two_synthesized_consumers_change(self):
        changed = recipe.transform(self.core)
        old = recipe.fill_body(self.core)
        new = recipe.fill_body(changed)
        self.assertEqual(old, new.replace('mem_read_ack', 'mem_ack'))
        self.assertEqual(new.count('mem_read_ack'), 2)
        self.assertIn('assert (ic_fill_en === ic_fill_before_read_ack)', changed)
        self.assertIn('if (ic_fill_en) assert (!mem_we)', changed)
        # Outside the fill and the simulation-only observer, all text is intact.
        original_tail = self.core[self.core.index(recipe.END):]
        self.assertEqual(changed[changed.index(recipe.END):], original_tail)

    def test_drift_and_reapplication_rejected(self):
        for source in (self.core+'\n', self.core.replace('!exec_flush_all', "1'b1", 1),
                       recipe.transform(self.core)):
            with self.assertRaises(ValueError):
                recipe.transform(source)

    def test_guard_and_payload_extraction(self):
        template = Path(__file__).with_name('ic_fill_read_ack_leaf.svh').read_text()
        source = source_text(self.core, self.bus, template)
        for marker in ('FRONTEND', 'REQUESTS', 'BRANCH', 'FILL_BODY'):
            self.assertNotIn(marker, source)
        self.assertIn('      S_PF:    begin bd_req =1\'b1; end', self.bus)
        self.assertEqual(source.count('ic_fill_data = mem_rdata;'), 4)
        self.assertIn('pipe_frontend_ready = pipe_bytes_ok && !pipe_fetch_checked_handoff;', source)
        self.assertIn('pipe_store_req = pipe_mem_active_q ?', source)
        self.assertIn('(!pipe_mem_active_q || mutant==3)', source)
        self.assertIn('(!exec_flush_all || mutant==4)', source)

    def test_build_requires_native_nonvacuous_proof(self):
        counts = dict(samples=50_331_648, pf=1, word0=1, completed=1, fragment=1,
                      noack=1, flush=1, held=1, diverted=1, bypass=1)
        rows = [dict(profile='early', mutant=i, build_exit=0,
                     native_exit=1 if i else 0, counts=counts) for i in range(5)]
        rows.append(dict(profile='fallback', mutant=0, build_exit=0, native_exit=0, counts=counts))
        good = dict(passed=True, pins_unchanged=True, errors=[], rows=rows)
        check_leaf(good)
        for key in counts:
            bad = copy.deepcopy(good)
            bad['rows'][0]['counts'][key] = 0
            with self.assertRaises(AssertionError): check_leaf(bad)
        for i in range(1, 5):
            bad = copy.deepcopy(good); bad['rows'][i]['native_exit'] = 0
            with self.assertRaises(AssertionError): check_leaf(bad)
        bad = copy.deepcopy(good); bad['rows'][-1]['native_exit'] = 1
        with self.assertRaises(AssertionError): check_leaf(bad)


if __name__ == '__main__':
    unittest.main()
