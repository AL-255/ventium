#!/usr/bin/env python3
"""Observation-only disjoint store-wait counters, excluded from synthesis."""

MASTER = '''
`ifndef SYNTHESIS
`ifdef VEN_WBUF_STALL_PROFILE
  longint unsigned wprof_admit, wprof_wait[6], wprof_head[4];
  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      wprof_admit <= 0;
      foreach(wprof_wait[i]) wprof_wait[i] <= 0;
      foreach(wprof_head[i]) wprof_head[i] <= 0;
    end else begin
      if(wr_enq) wprof_admit <= wprof_admit + 1;
      if(m_req && m_we && !m_ack) begin
        if(fatal_now || alias_bad) wprof_wait[0] <= wprof_wait[0]+1;
        else if(shutdown) wprof_wait[1] <= wprof_wait[1]+1;
        else if(rst != R_IDLE) wprof_wait[2] <= wprof_wait[2]+1;
        else if(wq_count == WBUF_CNTW'(P5_WBUF_DEPTH)) begin
          wprof_wait[3] <= wprof_wait[3]+1;
          if(wq_issued[wq_rp]) wprof_head[0] <= wprof_head[0]+1;
          else if(wr_active && wr_active_slot == wq_rp) begin
            if(!(aw_done || aw_hs)) wprof_head[1] <= wprof_head[1]+1;
            else if(!(w_done || w_hs)) wprof_head[2] <= wprof_head[2]+1;
            else wprof_head[3] <= wprof_head[3]+1;
          end else wprof_head[3] <= wprof_head[3]+1;
        end
        else if(wq_count == WBUF_CNTW'(1)) wprof_wait[4] <= wprof_wait[4]+1;
        else wprof_wait[5] <= wprof_wait[5]+1;
      end
    end
  end
  final begin
    $display("[WBUFSTALL] admits=%0d fault=%0d shutdown=%0d read_fsm=%0d full=%0d one=%0d empty=%0d",
      wprof_admit,wprof_wait[0],wprof_wait[1],wprof_wait[2],wprof_wait[3],wprof_wait[4],wprof_wait[5]);
    $display("[WBUFSTALL] full_head b_pending=%0d aw_wait=%0d w_wait=%0d dispatch_or_final=%0d",
      wprof_head[0],wprof_head[1],wprof_head[2],wprof_head[3]);
  end
`endif
`endif
'''

L1 = '''
`ifndef SYNTHESIS
`ifdef VEN_WBUF_STALL_PROFILE
  longint unsigned wprof_ack, wprof_wait[6];
  always_ff @(posedge clk) begin
    if(!rst_n) begin
      wprof_ack <= 0;
      foreach(wprof_wait[i]) wprof_wait[i] <= 0;
    end else if(c_req && c_we) begin
      if(c_ack) wprof_ack <= wprof_ack+1;
      else if(st == L1_FILL) wprof_wait[0] <= wprof_wait[0]+1;
      else if(st == L1_BYP) wprof_wait[1] <= wprof_wait[1]+1;
      else if(st == L1_DONE) wprof_wait[2] <= wprof_wait[2]+1;
      else if(st == L1_IDLE && m_req && m_we && !m_ack) wprof_wait[3] <= wprof_wait[3]+1;
      else if(st == L1_IDLE) wprof_wait[4] <= wprof_wait[4]+1;
      else wprof_wait[5] <= wprof_wait[5]+1;
    end
  end
  final $display("[L1DSTORESTALL] ack=%0d fill=%0d bypass=%0d done=%0d backing=%0d idle_other=%0d other=%0d",
    wprof_ack,wprof_wait[0],wprof_wait[1],wprof_wait[2],wprof_wait[3],wprof_wait[4],wprof_wait[5]);
`endif
`endif
'''


def transform(text, module):
    if module not in ('ven_axi_master', 'ven_l1d'):
        raise ValueError('unknown module')
    if 'VEN_WBUF_STALL_PROFILE' in text or text.count('endmodule') != 1:
        raise ValueError('ambiguous or already instrumented source')
    return text.replace('endmodule', (MASTER if module == 'ven_axi_master' else L1) + '\nendmodule')
