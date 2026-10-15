"""Private current-U/V-read interface specialization; not a global feature cut.

Default cache clients retain standalone pairs and optional predecessor priming.
Only the core configuration whose sole producer is pipe_v_pair_request opts in.
Requests lacking a live U are deliberately rejected, not claimed equivalent.
"""
import hashlib

PARENTS = {
    'rtl/mem/ven_l1d.sv': '62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3',
    'rtl/mem/ventium_l1_axi.sv': '4e923bc360a388c113c0ee9936e5f39e90411707aeb2c59806683398e3a610ec',
    'rtl/ventium_top.sv': '0e324c5df71112df2f583218df305946fd99904847dd72b5cf7ae78007415b91',
}
OLD_LOOKUP = '''  assign pair_lookup_active = (|pair_req_valid) && (st == L1_IDLE) &&
      (((!c_req && !rd_armed) && !mc_lookup_next) ||
       (pair_legacy_bank_owned && !mc_lookup_next) || pair_legacy_capture ||
       pair_prime_capture || pair_store_read_capture) &&
      !early_armed && !stream_path &&
      !flush_all && !snoop_inv_valid && !golden;
'''
NEW_LOOKUP = '''  // This interface contract is selected only by a core whose sideband
  // describes V behind a current U read. Generic clients retain the original
  // arbitration. In particular, do not remove their next-lookup exclusion.
  // A squashed/denied U creates no V owner in the specialized interface.
  assign pair_lookup_active = (|pair_req_valid) && (st == L1_IDLE) &&
      (PAIR_CURRENT_U_ONLY ? pair_legacy_capture :
       (((!c_req && !rd_armed) && !mc_lookup_next) ||
        (pair_legacy_bank_owned && !mc_lookup_next) || pair_legacy_capture ||
        pair_prime_capture || pair_store_read_capture)) &&
      !early_armed && !stream_path &&
      !flush_all && !snoop_inv_valid && !golden;
'''


def once(source, old, new):
    if source.count(old) != 1:
        raise ValueError('current-U specialization anchor drift')
    return source.replace(old, new)


def transform(source, name):
    if hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('current-U predecessor drift/reapplication')
    if name == 'rtl/mem/ven_l1d.sv':
        source = once(source, '    parameter int L1_SETS = 128,',
            '    // 1: lane 1 is only V accompanying a live current U read.\n'
            '    // 0: preserve the general standalone/primed two-lane interface.\n'
            "    parameter bit PAIR_CURRENT_U_ONLY = 1'b0,\n"
            '    parameter int L1_SETS = 128,')
        source = once(source, OLD_LOOKUP, NEW_LOOKUP)
        source = once(source,
            '    assert (pair_lookup_active === pair_lookup_before_ack_cut)',
            '    assert (PAIR_CURRENT_U_ONLY ||\n'
            '            pair_lookup_active === pair_lookup_before_ack_cut)')
        anchor = '  assign pair_bank_ready = pair_lookup_active ?\n'
        witness = '''`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && PAIR_CURRENT_U_ONLY) begin
    // Exact equivalence on this client's live-U request domain; rejection
    // outside it is intentional and must not be hidden by this assertion.
    if (c_req && !c_we && pair_req_valid == 2'b10)
      assert (pair_lookup_active === pair_lookup_before_ack_cut)
        else $fatal(1, "CURRENT-U-PAIR: changed live U admission");
    if (pair_lookup_active)
      assert (c_req && !c_we && !rd_armed && pair_req_valid == 2'b10)
        else $fatal(1, "CURRENT-U-PAIR: accepted without current U");
  end
`endif
'''
        source = once(source, anchor, witness + anchor)
        # Parameters are selected by integration, never inferred from a late
        # c_next_req signal. Reject incompatible explicit specialization.
        guard = '''  initial begin
    if (PAIR_CURRENT_U_ONLY) begin
`ifndef VEN_P54_DUAL_LOAD_PAIR
      $fatal(1, "CURRENT-U-PAIR requires dual current-U load pairing");
`endif
`ifdef VEN_P54_DUAL_LOAD_PRIME
      $fatal(1, "CURRENT-U-PAIR excludes predecessor paired-load priming");
`endif
`ifdef VEN_P54_STORE_LOAD_PAIR
      $fatal(1, "CURRENT-U-PAIR excludes U-store/V-load clients");
`endif
    end
  end
'''
        source = once(source, '  // REVIEW2 M-04: this module ADVERTISED',
                      guard + '  // REVIEW2 M-04: this module ADVERTISED')
    elif name == 'rtl/mem/ventium_l1_axi.sv':
        source = once(source, 'module ventium_l1_axi #(\n',
            "module ventium_l1_axi #(\n    parameter bit PAIR_CURRENT_U_ONLY = 1'b0,\n")
        source = once(source,
            '  ven_l1d #(.L1_SETS(L1_SETS), .L1_LINE(L1_LINE)) u_l1d (',
            '  ven_l1d #(.L1_SETS(L1_SETS), .L1_LINE(L1_LINE),\n'
            '            .PAIR_CURRENT_U_ONLY(PAIR_CURRENT_U_ONLY)) u_l1d (')
    else:
        source = once(source, '                   .LINE_REPLAY(AXI_LINE_REPLAY),\n',
            '''                   .LINE_REPLAY(AXI_LINE_REPLAY),
`ifdef VEN_P54_DUAL_LOAD_PAIR
`ifndef VEN_P54_DUAL_LOAD_PRIME
`ifndef VEN_P54_STORE_LOAD_PAIR
                   // Here core.sv drives only {pipe_v_pair_request, 1'b0}.
                   // No standalone or predecessor-prime pair client exists.
                   .PAIR_CURRENT_U_ONLY(1'b1),
`endif
`endif
`endif
''')
    return source
