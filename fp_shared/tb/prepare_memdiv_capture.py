"""Private memory-divide input stage for the measured fetch-probe FPU.

Capture raw bits before conversion, not the already-late floatx80 operand.
Only non-stack-fault memory FDIV/FDIVR gains one cycle, including specials.
Register arithmetic, the shared ALU and SRT iteration remain unchanged.
"""
import hashlib

PARENT = '76b259bdc51534127a7bed77f3389a5971ef6b3774e1229c0785e74474c1e5ef'
PAYLOAD = 'fp_shared/ven_fp_top.sv'


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('memory-divide capture predecessor drift/reapplication')
    changes = []

    def replace(old, new, count=1):
        nonlocal source
        if source.count(old) != count:
            raise ValueError('memory-divide capture ambiguous anchor: '+old[:80])
        source = source.replace(old, new)
        changes.append((old, new))

    replace('    TOP_TRANS\n', '    TOP_TRANS, TOP_MEMDIV\n')
    replace('  logic [81:0] div_special_raw;\n', '''  // Memory divide alone captures raw memory bits before format conversion.
  // Do not feed live cmd_mem through the SRT operand or special-result cones.
  // The existing register path and every other arithmetic service stay live.
  logic [79:0] div_mem_q, div_st0_q;
  logic [3:0] div_bytes_q;
  logic [2:0] div_aluop_q;
  logic div_bug_q;
  logic [79:0] div_a, div_b;
  logic [2:0] div_aluop;
  wire logic mem_arith_cmd = cmd_op inside {
      FX_AR_M32, FX_AR_M64, FX_AR_I16, FX_AR_I32};

  always_comb begin
    div_aluop = cmd_aluop;
    div_a = (cmd_op == FX_AR_STI_ST0) ? sti_data : st0_data;
    div_b = (cmd_op == FX_AR_STI_ST0) ? st0_data : sti_data;
    if (top_state == TOP_MEMDIV) begin
      div_aluop = div_aluop_q;
      div_a = div_st0_q;
      if (pending_op inside {FX_AR_I16, FX_AR_I32})
        div_b = f_mem_as_int(div_mem_q, div_bytes_q);
      else
        div_b = f_mem_as_float(div_mem_q, div_bytes_q);
    end
  end

  logic [81:0] div_special_raw;
''')
    replace('fp_perf_state [7]', 'fp_perf_state [8]')
    replace('i < 7; i++', 'i < 8; i++', 2)
    replace('is_div_arith(cmd_aluop) && !div_special_hit)\n',
            'is_div_arith(cmd_aluop) && (mem_arith_cmd || !div_special_hit))\n')
    replace('f_special(cmd_aluop, alu_a, alu_b)', 'f_special(div_aluop, div_a, div_b)')
    replace('f_zero_over_zero(cmd_aluop, alu_a, alu_b)',
            'f_zero_over_zero(div_aluop, div_a, div_b)')
    replace('f_div_by_zero(cmd_aluop, alu_a, alu_b)',
            'f_div_by_zero(div_aluop, div_a, div_b)')
    replace('fx_make(alu_a[79] ^ alu_b[79],', 'fx_make(div_a[79] ^ div_b[79],')
    replace('is_div_arith(cmd_aluop) && !div_special_hit) begin',
            'is_div_arith(cmd_aluop) && !mem_arith_cmd && !div_special_hit) begin', 2)
    # Both payload-selector configurations must start the same captured owner.
    replace("    srt_start = 1'b0;\n    if (accept", """    srt_start = 1'b0;
    if (top_state == TOP_MEMDIV) begin
      srt_start = !div_special_hit;
    end else if (accept""")
    replace("    if (accept && !issue_stack_fault &&\n        ((cmd_op == FX_AR_ST0_STI)",
            """    if (top_state == TOP_MEMDIV) begin
      srt_start = !div_special_hit;
    end else if (accept && !issue_stack_fault &&
        ((cmd_op == FX_AR_ST0_STI)""")
    replace("(cmd_aluop == 3'd7) ? alu_b : alu_a", "(div_aluop == 3'd7) ? div_b : div_a", 2)
    replace("(cmd_aluop == 3'd7) ? alu_a : alu_b", "(div_aluop == 3'd7) ? div_a : div_b", 2)
    replace('    if (top_state == TOP_TRANS) begin\n      if (trans_divide_start)',
            '''    if (top_state == TOP_MEMDIV) begin
      // Captured divide owner wins over a changing, unaccepted command bus.
      srt_mode = 2'd0;
    end else if (top_state == TOP_TRANS) begin
      if (trans_divide_start)''')
    replace('else if (is_div_arith(cmd_aluop) && div_special_hit) begin',
            'else if (is_div_arith(cmd_aluop) && !mem_arith_cmd && div_special_hit) begin')
    replace('    if ((top_state == TOP_SRT) && srt_done) begin\n', '''    if ((top_state == TOP_MEMDIV) && div_special_hit) begin
      c_write       = 1'b1;
      c_write_idx   = pending_dst;
      c_write_data  = div_special_result[79:0];
      c_status      = 1'b1;
      c_status_data = f_arith_fstat(fstat_o, div_special_result);
      c_status_data[9] = 1'b0;
      c_pop         = pending_pop ? 2'd1 : 2'd0;
    end

    if ((top_state == TOP_SRT) && srt_done) begin
''')
    replace("      srt_bug_q       <= 1'b0;\n", """      srt_bug_q       <= 1'b0;
      div_mem_q       <= '0;
      div_st0_q       <= '0;
      div_bytes_q     <= '0;
      div_aluop_q     <= '0;
      div_bug_q       <= 1'b0;
""")
    replace('''              end else if (is_div_arith(cmd_aluop)) begin
                if (div_special_hit) begin''', '''              end else if (is_div_arith(cmd_aluop)) begin
                if (mem_arith_cmd) begin
                  div_mem_q   <= cmd_mem;
                  div_st0_q   <= st0_data;
                  div_bytes_q <= cmd_mem_bytes;
                  div_aluop_q <= cmd_aluop;
                  div_bug_q   <= cmd_fdiv_bug;
                  pending_dst <= 3'd0;
                  pending_pop <= cmd_pop;
                  pending_op  <= cmd_op;
                  top_state   <= TOP_MEMDIV;
                end else if (div_special_hit) begin''')
    replace('        TOP_SRT: begin\n', '''        TOP_MEMDIV: begin
          if (div_special_hit) begin
            rsp_valid <= 1'b1;
            rsp_arith <= div_special_result;
            top_state <= TOP_IDLE;
          end else begin
            srt_bug_q <= div_bug_q;
            top_state <= TOP_SRT;
          end
        end

        TOP_SRT: begin
''')
    # Reject an accidentally broad replacement or an irreversible recipe.
    restored = source
    for old, new in reversed(changes):
        restored = restored.replace(new, old)
    if hashlib.sha256(restored.encode()).hexdigest() != PARENT:
        raise ValueError('memory-divide capture recipe does not reverse exactly')
    return source
