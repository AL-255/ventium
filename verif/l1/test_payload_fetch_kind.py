"""Host guards for the source-extracted request classes and hint-only recipe."""
import os
from pathlib import Path
import re
import unittest

import prepare_payload_code_hint as base
import prepare_payload_fetch_kind as refine
import run_payload_fetch_kind_leaf as leaf


class SourceContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = Path(os.environ['PAYLOAD_CODE_HINT_PARENT'])
        cls.original = {name: (parent/name).read_text() for name in base.HASHES}
        cls.raw = base.transform(cls.original)['rtl/core/core.sv']
        cls.refined = refine.transform(cls.raw)
        cls.bus = (parent/'rtl/core/core_bus_driver.svh').read_text()

    def test_only_the_hint_and_its_assertion_change(self):
        self.assertEqual(self.refined.replace(refine.NEW, refine.OLD), self.raw)
        self.assertEqual(self.refined.count('assign mem_code = mem_req && !cur_is_d;'), 1)
        self.assertIn('S_PIPE:        cur_is_d = pipe_load_req || pipe_store_req;', self.refined)
        self.assertIn('if (rst_n && mem_req)', refine.NEW)
        self.assertEqual(base.select_hint_branch(self.refined, False).split(),
                         self.original['rtl/core/core.sv'].split())

    def test_drift_and_reapplication_rejected(self):
        for text in (self.raw+'\n', self.refined):
            with self.assertRaises(ValueError):
                refine.transform(text)

    def test_downstream_stages_only_cancel_requests(self):
        tail = self.bus.rsplit('    endcase\n', 1)[1]
        tail = re.sub(r'//[^\n]*', '', tail)
        self.assertEqual(re.findall(r'\bbd_req\s*=\s*([^;]+);', tail), ["1'b0"]*3)
        self.assertIn("assign mem_req   = fx_wrsup_e ? 1'b0 : bd_req;", self.refined)

    def test_actual_classification_and_frontend_guards_extracted(self):
        core = self.original['rtl/core/core.sv']
        frontend, requests, branch = leaf.extract(core, self.bus)
        self.assertIn('pipe_frontend_ready = pipe_bytes_ok && !pipe_fetch_checked_handoff;', frontend)
        self.assertIn('pf_miss = (state==S_PIPE) && !pipe_mem_active_q', requests)
        self.assertIn('!pipe_bytes_ok && !pipe_fetch_checked_handoff;', requests)
        self.assertEqual(requests.count('exec_issue_ok && pipe_frontend_ready'), 2)
        self.assertEqual(requests.count('pipe_mem_active_q ?'), 2)
        self.assertIn('else if (pf_miss && exec_issue_ok)', branch)
        self.assertIn('if (pipe_load_req)', branch)
        self.assertIn('else if (pipe_store_req)', branch)


if __name__ == '__main__':
    unittest.main()
