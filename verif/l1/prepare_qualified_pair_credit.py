"""Private exact-parent AXI enqueue cofactor; not an acceptance profile.

The same-clock, no-L2 L1 supplies a pair request only after seeing pair credit.
Keep the unqualified master's original admission behavior as the default.
This removes only the redundant pair-credit recheck, not request admission,
quad combining, two-slot accounting, ordering, error handling or latency.
"""
import hashlib
import re

PINS = {
    'ven_axi_master.sv': 'ed11478bcf7898e410b5d9bd4f1952d8d3291037f38987c3c01eb935b9b13e38',
    'ventium_l1_axi.sv': '4e923bc360a388c113c0ee9936e5f39e90411707aeb2c59806683398e3a610ec',
    'ven_l1d.sv': '62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3',
}


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('missing/ambiguous fragment: '+old[:80])
    return text.replace(old, new)


def enqueue(source):
    start = source.index('  assign wr_enq      =')
    return source[start:source.index(';', start)+1]


def transform(sources):
    for name, expected in PINS.items():
        if hashlib.sha256(sources[name].encode()).hexdigest() != expected:
            raise ValueError('parent drift/reapplication: '+name)
    master, wrapper, cache = (sources[n] for n in PINS)
    # The source pins cover the complete drivers, not just these fragments.
    assert 'm_pair_req = c_pair_intent_ready;' in cache
    assert 'm_req = c_pair_intent_ready;' in cache
    assert 'assign c_pair_intent_ready = rst_n && c_req' in cache
    assert '(c_we ? m_pair_ready :' in cache
    assert 'assign b_pair_req = m_pair_req && !smram_deny;' in wrapper
    assert 'assign m_pair_ready = !smram_deny && b_pair_ready;' in wrapper
    assert 'assign axm_pair_req = b_pair_req;' in wrapper
    assert 'assign b_pair_ready = axm_pair_ready;' in wrapper
    old = enqueue(master)
    new = '''  assign wr_enq      = (rst == R_IDLE) && m_req && m_we && !shutdown &&
                       !alias_bad && !fatal_now &&
                       ((wq_count < WBUF_CNTW'(P5_WBUF_DEPTH)) || wq_head_release);'''
    master = once(master, '    parameter bit          LINE_REPLAY = 1\'b1,',
        '''    parameter bit          LINE_REPLAY = 1'b1,
    // Opt-in contract: every requested paired write already has m_pair_ready.
    // Only a directly connected, same-clock qualified L1 may enable this.
    // Generic producers that hold uncredited pairs MUST retain the default.
    parameter bit          PAIR_REQ_CREDIT_QUALIFIED = 1'b0,''')
    witness = '''
`ifndef SYNTHESIS
  logic wr_enq_unqualified;
OLD_ENQUEUE
  always_ff @(posedge core_clk) if (core_rst_n && PAIR_REQ_CREDIT_QUALIFIED) begin
    assert (!(m_req && m_we && m_pair_req) || m_pair_ready)
      else $fatal(1,"PAIR-CREDIT: unqualified producer request");
    assert (wr_enq === wr_enq_unqualified)
      else $fatal(1,"PAIR-CREDIT: enqueue behavior changed");
  end
`endif'''.replace('OLD_ENQUEUE', old.replace('wr_enq ', 'wr_enq_unqualified '))
    master = once(master, old,
        '  generate if (PAIR_REQ_CREDIT_QUALIFIED) begin : g_pair_credit_qualified\n'+new+
        '\n  end else begin : g_pair_credit_unqualified\n'+old+'\n  end endgenerate\n'+witness)
    wrapper = once(wrapper, '      .WATCHDOG   (WATCHDOG)\n  ) u_axi (',
        '''`ifdef VEN_P54_DUAL_STORE_PAIR
`ifndef VEN_AXI_CDC
      // No clock crossing or intervening L2 may weaken this live-credit contract.
      .PAIR_REQ_CREDIT_QUALIFIED (!EN_L2),
`endif
`endif
      .WATCHDOG   (WATCHDOG)
  ) u_axi (''')
    return dict(sources, **{'ven_axi_master.sv': master, 'ventium_l1_axi.sv': wrapper})


def assignment(source, name):
    matches = re.findall(r'  assign '+name+r'\s*=.*?;', source, re.S)
    if len(matches) != 1:
        raise ValueError('ambiguous assignment: '+name)
    return matches[0]
