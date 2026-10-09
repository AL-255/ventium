#!/usr/bin/env python3
"""Launch an admitted store only after all older payloads have been issued."""
from prepare_wbuf_empty_dispatch import transform as empty_transform


def transform(text):
    if 'VEN_P54_WBUF_ADMIT_DISPATCH' in text:
        raise ValueError('admission dispatch already present')
    text = empty_transform(text)
    old = '''  // The enqueue edge already captures the whole checked CPU payload. When
  // BOTH architectural slots are empty, capture it into the ordinary AXI
  // launch registers on that same edge. AW/W VALID still comes only from
  // registers; the store still occupies its P54 slot until its final B.
  // Never bypass an older queued/active store or change queue admission.
  wire wr_empty_dispatch = wr_enq && !wr_active &&
                           (wq_count == WBUF_CNTW'(0));'''
    new = '''  // Accept into the existing AXI launch registers when they become free,
  // but only after every older retained slot has issued its complete payload.
  // An already queued unissued store always wins (wr_dispatch). The old final
  // beat and its B accounting still use the pre-edge slot. The newly admitted
  // store takes its ordinary ring slot and remains there until its final B.
  // No new queue depth, combinational AXI VALID or read-order bypass.
  wire wr_head_payload_done = wq_issued[wq_rp] ||
      (wr_store_final && wr_active_slot == wq_rp);
  wire wr_second_payload_done = wq_issued[~wq_rp] ||
      (wr_store_final && wr_active_slot != wq_rp);
  wire wr_empty_dispatch = wr_enq && (!wr_active || wr_store_final) &&
      !wr_dispatch && ((wq_count == WBUF_CNTW'(0)) ||
       (wr_head_payload_done && ((wq_count == WBUF_CNTW'(1)) || wr_second_payload_done)));'''
    if text.count(old) != 1:
        raise ValueError('missing original empty predicate')
    text = text.replace(old, new)
    old = '''  wire [63:0] wr_launch_data = wr_empty_dispatch ?
      ({32'd0, m_wdata} << {m_addr[1:0], 3'b000}) : q_dsh;
  wire [7:0] wr_launch_strb = wr_empty_dispatch ?
      ({4'd0, m_wstrb} << m_addr[1:0]) : q_ssh;'''
    if text.count(old) != 1:
        raise ValueError('missing launch aligner')
    text = text.replace(old, '''  // Select the unaligned payload first, then share one byte-lane shifter.
  // Do not duplicate the old queue aligner for the live enqueue path.
  wire [31:0] wr_launch_raw_data = wr_empty_dispatch ? m_wdata : wq_wdata[wr_dispatch_slot];
  wire [3:0] wr_launch_raw_strb = wr_empty_dispatch ? m_wstrb : wq_wstrb[wr_dispatch_slot];
  wire [63:0] wr_launch_data = {32'd0, wr_launch_raw_data} << {wr_launch_addr[1:0], 3'b000};
  wire [7:0] wr_launch_strb = {4'd0, wr_launch_raw_strb} << wr_launch_addr[1:0];''')
    old = "            if (!wr_dispatch) wr_active <= 1'b0;"
    if text.count(old) != 1:
        raise ValueError('missing final-beat active ownership')
    text = text.replace(old, '''`ifdef VEN_P54_WBUF_EMPTY_DISPATCH
            if (!wr_launch) wr_active <= 1'b0;
`else
            if (!wr_dispatch) wr_active <= 1'b0;
`endif''')
    return text.replace('VEN_P54_WBUF_EMPTY_DISPATCH', 'VEN_P54_WBUF_ADMIT_DISPATCH')
