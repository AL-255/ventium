"""Separate read/write completion in the exact measured demand-width parent.

The existing read ACK has the same final-fragment qualifier. Neither request,
paired-store acceptance nor architectural commit is authorized by a new event.
"""
import hashlib

FILE = 'rtl/core/core.sv'
PARENT = 'fc02d7c55bfc0f33a0e8f87fdcf04d6a4709b97a420b8161e2d0effc0a854de1'
OLD = '  assign pipe_mem_wait = (pipe_load_req || pipe_store_req) && !mem_ack;\n'
NEW = '''  // Read owners need no backing-write/paired-store admission in their ACK.
  // Keep the existing final-fragment suppression and ordinary write ACK.
  assign pipe_mem_wait = (pipe_load_req && !mem_read_ack) ||
                         (pipe_store_req && !mem_ack);
'''
WITNESS = '''`ifndef SYNTHESIS
  logic pipe_wait_before_read_ack;
'''+OLD.replace('pipe_mem_wait', 'pipe_wait_before_read_ack')+'''  always_ff @(posedge clk) if (rst_n) begin
    assert (pipe_mem_wait === pipe_wait_before_read_ack)
      else $fatal(1,"PIPE-WAIT-READ-ACK: changed completion wait");
    assert (!(pipe_load_req && pipe_store_req))
      else $fatal(1,"PIPE-WAIT-READ-ACK: conflicting U owners");
    if (pipe_load_req) begin
      assert (!mem_we && (mem_read_ack === mem_ack))
        else $fatal(1,"PIPE-WAIT-READ-ACK: lost read owner");
      if ($test$plusargs("ven_pipe_wait_read_ack_witness") && mem_read_ack)
        $display("[PIPE-WAIT-READ-ACK] pc=%08x held=%0b paired=%0b",
                 pipe_commit_eip, pipe_mem_active_q, pipe_pair_eff);
    end
  end
`endif
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('pipeline wait predecessor drift/reapplication')
    if source.count(OLD) != 1:
        raise ValueError('ambiguous pipeline wait equation')
    return source.replace(OLD, NEW+WITNESS)
