#!/usr/bin/env python3
"""Opt-in registered empty-queue dispatch; retain both architectural P54 slots."""


def transform(text):
    if 'VEN_P54_WBUF_EMPTY_DISPATCH' in text:
        raise ValueError('empty dispatch already present')

    def replace(old, new):
        nonlocal text
        if text.count(old) != 1:
            raise ValueError('missing/ambiguous anchor: ' + old[:80])
        text = text.replace(old, new)

    replace('  // ---- AXI combinational drive ----------------------------------------------', '''`ifdef VEN_P54_WBUF_EMPTY_DISPATCH
  // The enqueue edge already captures the whole checked CPU payload. When
  // BOTH architectural slots are empty, capture it into the ordinary AXI
  // launch registers on that same edge. AW/W VALID still comes only from
  // registers; the store still occupies its P54 slot until its final B.
  // Never bypass an older queued/active store or change queue admission.
  wire wr_empty_dispatch = wr_enq && !wr_active &&
                           (wq_count == WBUF_CNTW'(0));
  wire wr_launch = wr_dispatch || wr_empty_dispatch;
  wire wr_launch_slot = wr_empty_dispatch ? wq_wp : wr_dispatch_slot;
  wire [31:0] wr_launch_addr = wr_empty_dispatch ? m_addr : wq_addr[wr_dispatch_slot];
  wire [63:0] wr_launch_data = wr_empty_dispatch ?
      ({32'd0, m_wdata} << {m_addr[1:0], 3'b000}) : q_dsh;
  wire [7:0] wr_launch_strb = wr_empty_dispatch ?
      ({4'd0, m_wstrb} << m_addr[1:0]) : q_ssh;
`ifdef VEN_P54_WBUF_QUAD_COMBINE
  wire wr_launch_fused = wr_empty_dispatch ? wr_quad_enq : wq_fused[wr_dispatch_slot];
  wire [31:0] wr_launch_hi = wr_empty_dispatch ? m_pair_wdata : wq_hi_data[wr_dispatch_slot];
`endif
`endif

  // ---- AXI combinational drive ----------------------------------------------''')
    start = text.index('      if (wr_dispatch) begin\n')
    end = text.index('\n      // AW and W complete independently', start)
    old = text[start:end]
    new = old.replace('if (wr_dispatch)', 'if (wr_launch)')
    for a, b in (
        ('wq_addr[wr_dispatch_slot]', 'wr_launch_addr'),
        ('q_dsh', 'wr_launch_data'), ('q_ssh', 'wr_launch_strb'),
        ('wq_fused[wr_dispatch_slot]', 'wr_launch_fused'),
        ('wq_hi_data[wr_dispatch_slot]', 'wr_launch_hi'),
        ('wr_active_slot <= wr_dispatch_slot', 'wr_active_slot <= wr_launch_slot'),
    ):
        if a not in new:
            raise ValueError('missing dispatch payload: ' + a)
        new = new.replace(a, b)
    replace(old, '`ifdef VEN_P54_WBUF_EMPTY_DISPATCH\n' + new +
            '\n`else\n' + old + '\n`endif\n')
    return text
