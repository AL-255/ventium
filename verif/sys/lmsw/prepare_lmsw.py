"""Hash-gated, unpromoted LMSW repair on the SMSW + endpoint-map core.

Use the existing serialized CR0 commit and precise load path. No workload
special cases, new FSM states, pipeline fallback or independent CR0 writer.
"""
import hashlib

PARENTS = {
    'core.sv': '08533031d86005383751f9f55807a9fcaa01dbd67d1476dc6569598e2e05b510',
    'decode_stages.sv': 'c156a3e2801c9d27bd83f002112c31dc30f513f1ca0849ec4186919511114f0b',
    'core_fetch_decode.svh': 'a6d6e78db60da34982accd9a43a83385f127c14c454c4b05548d0a86978e82be',
    'core_refdecode_latch.svh': 'f69c147b815b5e009240400112c537b50328cf3d9d574528bcdc87291d2dcd5f',
    'core_exec.svh': '8e3444b7214c5d9132632e95efc6e4a5a08db2aac88a8d893ecde46843db4f96',
}

LMSW_DECODE = """          end else if (modrm_reg==3'd6) begin
            // LMSW r/m16: operand size never changes the two-byte source.
            // Serialize through the existing CR0 commit, with CPL0 and precise
            // EA/segment/page checks. PE is sticky; high CR0 bits are preserved.
            if (sys_mode) begin
              d_sysop=SYS_MOVCR_TO; d_sys_creg=3'd0; d_lmsw=1'b1; d_w=3'd2;
              if (modrm_mod==2'b11) begin
                d_src_reg=modrm_rm; d_fetch_len=pfx_len+5'd3;
              end else begin
                d_mem_read=1'b1;
                begin fetch_ea_shape=1'b1; d_fetch_len=m_idx+mfl_e(eff_addr,modrm_mod,modrm_rm,has_sib,sib_base); end
              end
            end else begin d_unknown=1'b1; d_fetch_len=pfx_len+5'd3; end
"""

CR0_VALUE = """  // One actual CR0 value for commit and passive debug observers. LMSW's
  // memory source is the ordinary completed/merged load, never a live bus beat.
  wire [31:0] cr0_exec_value = q_clts ? (creg0 & ~32'h0000_0008) :
      q_lmsw ? ((creg0 & 32'hffff_fff1) |
                 {28'd0, (q_mem_read ? mem_load_data[3:0] : gpr_o[q_src_reg][3:0])}) :
      gpr_o[q_src_reg];
"""


def transform(source, name):
    if hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('LMSW source drift or reapplication: '+name)
    if name == 'decode_stages.sv':
        anchor = "          end else if (modrm_reg==3'd7 && modrm_mod!=2'b11) begin\n"
        edits = [
            ('    output logic        d_clts,          // REVIEW2 H-23: CLTS (0F 06)\n',
             '    output logic        d_clts,          // REVIEW2 H-23: CLTS (0F 06)\n'
             '    output logic        d_lmsw,          // LMSW (0F 01 /6), CR0 low bits\n'),
            ("    d_clts = 1'b0; d_smsw=1'b0;", "    d_clts = 1'b0; d_lmsw=1'b0; d_smsw=1'b0;"),
            (anchor, LMSW_DECODE+anchor),
            ('// register LGDT/LIDT, /6 LMSW etc deferred',
             '// register descriptor forms and reserved /5 are invalid'),
        ]
    elif name == 'core_refdecode_latch.svh':
        edits = [('q_br16<=d_br16; q_clts<=d_clts;',
                  'q_br16<=d_br16; q_clts<=d_clts; q_lmsw<=d_lmsw;')]
    elif name == 'core_fetch_decode.svh':
        anchor = '              SYS_MOVCR_FROM: state<=d_mem_write ? S_STORE : S_EXEC;\n'
        edits = [(anchor, anchor+
            '              // Only LMSW gives MOVCR_TO a memory source. Faults\n'
            '              // must complete before the shared S_EXEC CR0 commit.\n'
            '              SYS_MOVCR_TO: state<=d_mem_read ? S_LOAD : S_EXEC;\n')]
    elif name == 'core_exec.svh':
        edits = [("3'd0: creg0<= q_clts ? (creg0 & ~32'h0000_0008) : gpr_o[q_src_reg];",
                  "3'd0: creg0<=cr0_exec_value;")]
    else:
        edits = [
            ('    .d_clts        (d_clts),          // REVIEW2 H-23\n',
             '    .d_clts        (d_clts),          // REVIEW2 H-23\n'
             '    .d_lmsw        (d_lmsw),\n'),
            ('  logic        d_clts, q_clts;   // REVIEW2 H-23: CLTS (0F 06)\n',
             '  logic        d_clts, q_clts;   // REVIEW2 H-23: CLTS (0F 06)\n'
             '  logic        d_lmsw, q_lmsw;   // LMSW (0F 01 /6)\n'),
            ('  // latched M2S.1 system decode\n', CR0_VALUE+'\n  // latched M2S.1 system decode\n'),
            ('(gpr_o[q_src_reg][0] != creg0[0])) begin', '(cr0_exec_value[0] != creg0[0])) begin'),
            ('cn, creg0[0], gpr_o[q_src_reg][0], cs_d,', 'cn, creg0[0], cr0_exec_value[0], cs_d,'),
            ("if (q_clts || (((creg0 ^ gpr_o[q_src_reg]) & 32'h8000_0001) == 32'd0))",
             "if (((creg0 ^ cr0_exec_value) & 32'h8000_0001) == 32'd0)"),
        ]
    for before, after in edits:
        if source.count(before) != 1:
            raise ValueError('LMSW ambiguous/missing anchor: '+name)
        source = source.replace(before, after)
    return source
