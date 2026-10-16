"""Regression-driver, testbench completion and wrapper-fixture contracts."""
import os
from pathlib import Path
import subprocess
import unittest

import run_qualified_pair_credit_faults as faults
import run_qualified_pair_credit_wrapper as wrapper

HERE=Path(__file__).resolve().parent


class QualifiedPairFaults(unittest.TestCase):
    def test_existing_nonpair_stimulus_is_unchanged(self):
        added=".dbg_rd_valid(), .dbg_rd_addr(), .dbg_rd_data(),\n      "
        added+=".m_pair_req(1'b0), .m_pair_addr(32'd0), .m_pair_wdata(32'd0),\n"
        added+="      .m_pair_wstrb(4'd0), .m_pair_ready(), .m_pair_ack(),\n      "
        for label,top,_,_ in faults.CASES:
            if label.startswith('quad'):continue
            old=(HERE/(top+'.sv')).read_text()
            for candidate in (False,True):
                new=faults.fixture(old,candidate).replace(added,'')
                new=new.replace("ven_axi_master #(.PAIR_REQ_CREDIT_QUALIFIED(1'b1),",'ven_axi_master #(')
                self.assertEqual(old,new)

    def test_existing_quad_inputs_are_not_tied_off(self):
        old=(HERE/'tb_axi_quad_pair.sv').read_text()
        for qualified in (False,True):
            text=faults.fixture(old,qualified)
            self.assertIn('.m_pair_req, .m_pair_addr, .m_pair_wdata, .m_pair_wstrb,',text)
            self.assertNotIn(".m_pair_req(1'b0)",text)

    def test_quad_finish_is_outside_the_poll_loop(self):
        text=(HERE/'tb_axi_quad_pair.sv').read_text()
        loop=text[text.index('    for (int i = 0; i < 150; i++)'):text.index('    if (!completed)')]
        self.assertNotIn('$finish',loop)
        self.assertEqual(loop.count('completed = 1;'),2)
        self.assertEqual(loop.count('break;'),2)
        self.assertIn('if (!completed) $fatal(1, "timeout");',text)

    def test_actual_shell_grader_rejects_late_fatal_even_after_pass(self):
        script=(HERE/'run-axi-quad-pair-gate.sh').read_text()
        grader=script[script.index("if grep -Eq '%Fatal|"):]
        good='AXI-QUAD-PAIR-GATE-OK aw=2 w=3 b=2\n'
        for log,status in ((good,0),(good+'[190] %Fatal: timeout\n',1),
                           (good+'%Error: bad\n',1),(good+'FAIL: bad\n',1),('no marker\n',1)):
            run=subprocess.run(['bash','-c',grader],env=dict(os.environ,OUT=log,
                marker='AXI-QUAD-PAIR-GATE-OK'),capture_output=True,text=True,timeout=5)
            self.assertEqual(run.returncode,status,run.stdout+run.stderr)

    def test_wrapper_uses_real_reset_and_ports(self):
        text=wrapper.fixture()
        leaf=(HERE/'qualified_pair_credit_wrapper.svh').read_text()
        self.assertIn('.axi_rst_n(rst_n && !axi_only_reset)',text)
        self.assertIn('.core_store_pair_intent(store_pair_req)',text)
        self.assertIn('.m_axi_arready(arready && allow_ar)',text)
        self.assertIn('.arvalid(arvalid && allow_ar)',text)
        self.assertNotRegex(text+leaf,r'(?m)^\s*(force|release)\s')
        for item in ('denied U reached backing','reset retry','final RAM','split atomic pair'):
            self.assertIn(item,leaf)


if __name__=='__main__':unittest.main()
