"""Exact-parent, default-off parallel AXI write admission experiment.

Unlike the rejected qualified-credit experiment, this retains generic producer
semantics: no assumption that a requested pair already has credit. Payload-only
single/pair predicates precede the late request mux. Two kept combinational
nets preserve that intended cut; there is no new register or queue entry.
"""
import hashlib

from prepare_qualified_pair_credit import PINS, once, enqueue


def admission(old):
    return '''  generate if (PARALLEL_WRITE_ADMISSION) begin : g_parallel_write
    // Write extent is independent of direction, request, and pair selection.
    // Keep the original exact spill and high-BIOS-shadow rules, even for
    // generic masks and held, currently uncredited producer requests.
    logic [31:0] write_alias_last;
    logic write_alias_bad, pair_write_alias_bad;
    assign write_alias_last = {m_addr[31:2], 2'b00} +
                              ((alias_ssh[7:4] != 4'd0) ? 32'd7 : 32'd3);
    assign write_alias_bad = !(m_addr >= 32'hFFFE_0000) &&
                             (((m_addr & ~ADDR_MASK) != 32'd0) ||
                              ((write_alias_last & ~ADDR_MASK) != 32'd0));
    assign pair_write_alias_bad = !(m_pair_addr >= 32'hFFFE_0000) &&
                                  (((m_pair_addr & ~ADDR_MASK) != 32'd0) ||
                                   ((pair_alias_last & ~ADDR_MASK) != 32'd0));
    // Preserve these two cut points through synthesis. In particular, do
    // not merge m_req/m_we/m_pair_req back into extent or credit arithmetic.
    // A readiness predicate is NOT an ACK and never mutates retained state.
    (* keep = "true" *) logic single_admit, pair_admit;
    assign single_admit = (rst == R_IDLE) && !shutdown && !fatal_now &&
                          !write_alias_bad &&
                          ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release);
    assign pair_admit = (rst == R_IDLE) && !shutdown && !fatal_now &&
                        !write_alias_bad && !pair_write_alias_bad &&
                        (wr_can_pair
`ifdef VEN_P54_WBUF_QUAD_COMBINE
                         || (pair_quad_ok &&
                             ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release))
`endif
                        );
    assign wr_enq = m_req && m_we && (m_pair_req ? pair_admit : single_admit);
`ifndef SYNTHESIS
    logic original_enq;
ORIGINAL
    always_ff @(posedge core_clk) if (core_rst_n)
      assert (wr_enq === original_enq)
        else $fatal(1, "PARALLEL-WRITE: changed admission");
`endif
  end else begin : g_original_write
DEFAULT
  end endgenerate'''.replace('ORIGINAL', old.replace('wr_enq ', 'original_enq ')).replace('DEFAULT', old)


def transform(sources):
    for name, pin in PINS.items():
        if hashlib.sha256(sources[name].encode()).hexdigest() != pin:
            raise ValueError('parent drift/reapplication: '+name)
    master = sources['ven_axi_master.sv']
    master = once(master, "    parameter bit          LINE_REPLAY = 1'b1,", """    parameter bit          LINE_REPLAY = 1'b1,
    // Timing experiment; generic admission semantics, no caller assumption.
    parameter bit          PARALLEL_WRITE_ADMISSION = 1'b0,""")
    old = enqueue(master)
    master = once(master, old, admission(old))
    wrapper = once(sources['ventium_l1_axi.sv'], '      .WATCHDOG   (WATCHDOG)\n  ) u_axi (', '''`ifdef VEN_P54_DUAL_STORE_PAIR
`ifndef VEN_AXI_CDC
      .PARALLEL_WRITE_ADMISSION (!EN_L2),
`endif
`endif
      .WATCHDOG   (WATCHDOG)
  ) u_axi (''')
    return dict(sources, **{'ven_axi_master.sv': master, 'ventium_l1_axi.sv': wrapper})
