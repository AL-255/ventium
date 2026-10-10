"""Extend the critical-owner fixture for the existing earlier code-reuse ACK.

No RTL or data expectation changes. Keep the original registered-owner and
hold-until-ACK paths. The code-reuse path samples its own earlier handshake,
then checks a fresh request after the unrelated critical response arrives.
"""
ANCHOR = '    if (!hold_b) require_true(dut.do_rd_cap, "resident A was not captured on B critical-beat edge");'
EXTRA = '''`ifdef VEN_L1D_CODE_WORD_REUSE
    if (code_a && !hold_b) begin
      // This profile already ACKs A from its saved instruction line on B's
      // first backing edge. Requiring an extra capture here was a stale
      // structural assumption. Sample the REAL architectural handshake.
      require_true(dut.code_word_reuse && !dut.do_rd_cap && c_ack,
                   "code reuse did not own its earlier ACK");
      @(posedge clk);
      require_true(c_ack && c_rdata == backing_word(A),
                   "early code ACK sampled the wrong owner");
      @(negedge clk); c_req=0;
      require_true(dut.early_armed && dut.early_addr_q == B && !dut.early_match,
                   "B critical owner corrupted or mistaken for consumed A");
      @(posedge clk); @(negedge clk);
      c_req=1; c_addr=A;
      #1;
      require_true(dut.code_word_reuse && c_ack,
                   "new A transaction lost the saved code word");
      @(posedge clk);
      require_true(c_ack && c_rdata == backing_word(A),
                   "new code ACK sampled B's retained critical bytes");
      $display("L1D-CODE-OWNER-OK earlier_ack=1 second_transaction=1 checks=%0d",checks);
      $finish;
      disable owner_scenario; // $finish does not stop this active SV process immediately.
    end
`endif
'''


def transform(source):
    initial = '  initial begin\n    hold_b ='
    if 'owner_scenario' in source or 'L1D-CODE-OWNER-OK' in source:
        raise ValueError('already adapted owner fixture')
    for anchor in (initial, ANCHOR):
        if source.count(anchor) != 1:
            raise ValueError('missing/ambiguous original owner witness: '+anchor)
    return source.replace(initial, '  initial begin : owner_scenario\n    hold_b =').replace(ANCHOR, EXTRA+ANCHOR)
