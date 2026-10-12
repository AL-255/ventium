"""Use the existing final-fragment read ACK for immediate V-load acceptance.

The measured query-selector critical path still takes the backing-write ACK
mux through this read-only consumer. No architectural ACK or request changes.
"""
import hashlib

PAYLOAD = 'rtl/core/core.sv'
PARENT = '70cc3e386aaa7c359b09021cd6c3e38803bfd6ab93533ede73611a74f9694837'
OLD = '''  assign pipe_v_pair_now_accept = pipe_v_pair_request && mem_pair_now_valid &&
      mem_ack && !pipe_mem_active_q;
'''
NEW = OLD.replace('mem_ack', 'mem_read_ack')
WITNESS = '''`ifndef SYNTHESIS
  logic pair_now_before_read_ack;
'''+OLD.replace('pipe_v_pair_now_accept', 'pair_now_before_read_ack')+'''  always_ff @(posedge clk) if (rst_n) begin
    assert (pipe_v_pair_now_accept === pair_now_before_read_ack)
      else $fatal(1, "PAIR-NOW-READ-ACK: immediate V acceptance changed");
    if (pipe_v_pair_request && mem_pair_now_valid && !pipe_mem_active_q) begin
      assert (!mem_we && (mem_read_ack === mem_ack))
        else $fatal(1, "PAIR-NOW-READ-ACK: response lost read ownership");
      if ($test$plusargs("ven_pair_now_read_ack_witness") && pipe_v_pair_now_accept)
        $display("[PAIR-NOW-READ-ACK] pc=%08x vaddr=%08x byte=%0b",
                 eip, pipe_v_pair_phys, pipe_v_eff.w8);
    end
  end
`endif
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('immediate pair read-ACK predecessor drift/reapplication')
    if source.count(OLD) != 1:
        raise ValueError('immediate pair read-ACK consumer drift')
    return source.replace(OLD, NEW+WITNESS)
