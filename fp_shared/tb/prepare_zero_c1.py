"""Complete the ordinary zero-C1 class without changing execution latency.

Apply after prepare_fld_c1. Direct unary/exchange commands clear C1 at their
real commit, before stack-fault override. Deferred FBLD clears it only when
its owned conversion completes; stack overflow never starts that engine.
"""

def transform(text):
    old = ("      if (c_push) begin\n"
           "        c_status = 1'b1;\n"
           "        c_status_data[9] = 1'b0;\n"
           "      end\n\n"
           "      // Stack faults override the ordinary issue path.")
    new = ("      // P54 table 6-4 also defines zero C1 for FABS/FCHS/FXCH.\n"
           "      if (c_push || c_swap ||\n"
           "          (cmd_op == FX_FABS) || (cmd_op == FX_FCHS)) begin\n"
           "        c_status = 1'b1;\n"
           "        c_status_data[9] = 1'b0;\n"
           "      end\n\n"
           "      // Stack faults override the ordinary issue path.")
    bcd = ("    if ((top_state == TOP_BCD_LOAD) && bcd_load_done) begin\n"
           "      c_push      = 1'b1;\n"
           "      c_push_data = bcd_load_result;\n"
           "    end")
    fixed = bcd[:-7] + ("      // Valid packed decimal converts exactly, independent of RC/PC.\n"
                       "      // Faulting pushes complete at issue and never reach this owner.\n"
                       "      c_status = 1'b1;\n"
                       "      c_status_data[9] = 1'b0;\n"
                       "    end")
    if text.count(old) != 1 or text.count(bcd) != 1:
        raise ValueError('missing, ambiguous or already repaired zero-C1 commit')
    return text.replace(old, new).replace(bcd, fixed)
