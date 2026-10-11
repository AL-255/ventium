"""Separate FP read acknowledgement from store admission, without new cycles.

Private candidate recipe only. Existing acceptance/ownership predicates stay
intact; every consumer still sees the fragment engine's final-beat gate.
"""
import hashlib
import re

PARENTS = {
    'rtl/core/core.sv': 'b1e4686a9b28bbdae3586d9e7007c15429a343a3b72865186020931316abfcf7',
    'rtl/ventium_top.sv': '63c36a4fe6399b4a246fb8501f924f920c7a0d53e0ff1245accb0c2ff6a52ca2',
    'rtl/mem/ven_l1d.sv': '11ed3337a28f0eebd546860ad2abad7996352036d2fc86c930b578009e0c42e0',
    'rtl/mem/ventium_l1_axi.sv': 'b81c51b8ca88933607137116b48d6658cc6204476e502289afa1630918817db1',
}

READ_ACK = '''`ifdef VEN_FP_LOAD_EARLY_CMD
  // Read-only response cofactor: no backing-write or paired-store admission.
  // This is equal to c_ack whenever c_we is zero. It is NOT another grant,
  // request or response owner; only read-qualified consumers may use it.
  always_comb begin
    c_read_ack = 1'b0;
    if (c_req && !c_we) begin
`ifdef VEN_L1D_COMB_ACK
      c_read_ack = (rd_hit && (st==L1_IDLE) && !flush_all && !snoop_inv_valid
                    && !(BYPASS_RD_EN && !cacheable))
                 || ((st==L1_BYP) && byp_match);
`else
      c_read_ack = window_reuse || shadow_reuse ||
`ifdef VEN_L1D_CODE_WORD_REUSE
                   code_word_reuse ||
`endif
                   (early_match && !flush_all && !snoop_inv_valid)
                   || (rd_match && !flush_all && !snoop_inv_valid
                      && !(BYPASS_RD_EN && !cacheable))
                   || ((st==L1_BYP) && byp_match);
`endif
    end
`ifdef VEN_L1D_HIT_STREAM
    if (stream_path)
      c_read_ack = c_hit_stream && c_rsp_valid && c_rsp_ready;
`endif
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && !c_we)
    assert (c_read_ack === c_ack)
      else $fatal(1, "FP-READ-ACK: changed read response");
`endif
`endif

'''


def guarded(text):
    return '`ifdef VEN_FP_LOAD_EARLY_CMD\n' + text + '`endif\n'


def transform(name, source):
    if name not in PARENTS or hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('FP read ACK source drift: ' + name)
    edits = []
    def edit(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise ValueError('ambiguous FP read ACK edit: ' + repr(old))
        source = source.replace(old, new)
        edits.append((old, new))
    def after(old, added):
        edit(old, old + added)
    if name == 'rtl/mem/ven_l1d.sv':
        after('    output logic        c_ack,\n', guarded('    output logic        c_read_ack,\n'))
        marker = '  // core-side response: HIT (read) returns combinationally; a write acks with the\n'
        edit(marker, READ_ACK + marker)
        edit('      c_ack && (c_wstrb == 4\'hf) && cacheable && !golden &&\n',
             guarded('      c_read_ack &&\n') + '`ifndef VEN_FP_LOAD_EARLY_CMD\n      c_ack &&\n`endif\n'
             "      (c_wstrb == 4'hf) && cacheable && !golden &&\n")
    elif name == 'rtl/mem/ventium_l1_axi.sv':
        after('    output logic        core_ack,\n', guarded('    output logic        core_read_ack,\n'))
        after('  logic l1d_c_req; logic l1d_c_ack; logic [31:0] l1d_c_rdata;\n',
              guarded('  logic l1d_c_read_ack;\n'))
        after("                    : ((core_smram_deny || core_route_deny) && core_req) ? 1'b1 : l1d_c_ack;\n",
              guarded("  assign core_read_ack = !seam_core_rst_n ? 1'b0\n"
                      "                       : dma_drain_stall ? 1'b0\n"
                      "                       : ((core_smram_deny || core_route_deny) && core_req) ? 1'b1 : l1d_c_read_ack;\n"))
        after('      .c_ack   (l1d_c_ack),\n', guarded('      .c_read_ack(l1d_c_read_ack),\n'))
        edit('  assign core_rdata_hi_valid = l1d_c_req && l1d_c_ack &&\n',
             '  assign core_rdata_hi_valid = l1d_c_req &&\n' + guarded('      l1d_c_read_ack &&\n') +
             '`ifndef VEN_FP_LOAD_EARLY_CMD\n      l1d_c_ack &&\n`endif\n')
    elif name == 'rtl/ventium_top.sv':
        after('  logic        core_mem_ack;\n', guarded('  logic        core_mem_read_ack;\n'))
        after('      .bus_ack      (core_mem_ack),\n', guarded('      .bus_read_ack (core_mem_read_ack),\n'))
        after('  logic [31:0] l1_c_rdata; logic l1_c_ack; logic l1_bus_err;\n',
              guarded('  logic l1_c_read_ack;\n'))
        after('      .core_ack  (l1_c_ack),\n', guarded('      .core_read_ack(l1_c_read_ack),\n'))
        after('  assign core_mem_ack   = l1axi_en ? l1_c_ack   : (bus_mode ? bus_c_ack   : mem_ack);\n',
              guarded('  assign core_mem_read_ack = l1axi_en ? l1_c_read_ack : (bus_mode ? bus_c_ack : mem_ack);\n'))
        after('  assign core_mem_ack   = bus_mode ? bus_c_ack   : mem_ack;\n',
              guarded('  assign core_mem_read_ack = bus_mode ? bus_c_ack : mem_ack;\n'))
    elif name == 'rtl/core/core.sv':
        after('    input  logic        bus_ack,\n', guarded('    input  logic        bus_read_ack,\n'))
        after('  assign mem_ack   = bus_ack && !fx_hold_e;\n',
              '  logic mem_read_ack;\n' + guarded('  assign mem_read_ack = bus_read_ack && !fx_hold_e;\n'
              '`ifndef SYNTHESIS\n'
              '  always_ff @(posedge clk) if (rst_n && !mem_we)\n'
              '    assert (mem_read_ack === mem_ack)\n'
              '      else $fatal(1, "FP-READ-ACK: final fragment response changed");\n'
              '`endif\n') + '`ifndef VEN_FP_LOAD_EARLY_CMD\n  assign mem_read_ack = mem_ack;\n`endif\n')
        edit('      q_f_mem_read && !q_f_mem_write && mem_ack && fsm_case_enabled &&\n',
             '      q_f_mem_read && !q_f_mem_write && mem_read_ack && fsm_case_enabled &&\n')
        edit('      (f_step == 4\'d0) && fsm_case_enabled && mem_ack && bus_rdata_hi_valid &&\n',
             '      (f_step == 4\'d0) && fsm_case_enabled && mem_read_ack && bus_rdata_hi_valid &&\n')
    # Make every change explicit and reversible. This includes the two high-half
    # valid gates; leaving either on unified ACK would retain the same cone.
    check = source
    for old, new in reversed(edits):
        if check.count(new) != 1:
            raise ValueError('non-reversible FP read ACK edit')
        check = check.replace(new, old)
    if hashlib.sha256(check.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('FP read ACK changed unrelated text')
    return source


def ack_block(source):
    """Extract the actual parent response block, removing only data assignments."""
    marker = '  // core-side response: HIT (read) returns combinationally;'
    start = source.index('  always_comb begin', source.index(marker))
    end = source.index('\n`ifndef SYNTHESIS\n`ifndef VEN_L1D_COMB_ACK', start)
    block = re.sub(r'/\*.*?\*/|//[^\n]*', '', source[start:end], flags=re.S)
    block, count = re.subn(r'\bc_rdata\s*=\s*[^;]+;', '', block)
    if count != 3:
        raise ValueError('response payload structure drift')
    return block


def read_ack_block(source):
    start = source.index('  always_comb begin', source.index('// Read-only response cofactor:'))
    end = source.index('\n`ifndef SYNTHESIS', start)
    return source[start:end]
