"""Private exact-parent remainder repair: nearest small quotient and subnormals.

Reuse the existing remainder normalize/subtract state, with no normal-operation
pipeline stage or duplicated iterative engine. Not a canonical RTL promotion.
"""
import hashlib

PARENT_SHA='40b3e77b051bb674f99a30f3c9eb37566c06b32487d567a9ee78eaccbb833cbb'


def once(text,before,after):
    if text.count(before)!=1:
        raise ValueError('remainder anchor drift: '+before[:80])
    return text.replace(before,after)


def transform(text):
    if hashlib.sha256(text.encode()).hexdigest()!=PARENT_SHA:
        raise ValueError('remainder parent drift or repeated application')
    text=once(text,'  logic                rc2, rprem1;\n',
        '  logic                rc2, rprem1;\n'
        '  logic                rsmall_half; // small nearest quotient, exponent gap -1\n')
    text=once(text,"              rsa<=rem_input_a[79]; rem_q012<=3'd0; rem_c2<=1'b0; rem_ie<=1'b0; rprem1<=prem1;\n",
        "              rsa<=rem_input_a[79]; rem_q012<=3'd0; rem_c2<=1'b0; rem_ie<=1'b0; rprem1<=prem1;\n"
        "              rsmall_half <= 1'b0;\n")
    before='''                rexpd = rea_a - reb_a;
                if (rexpd < 0 || (rexpd==0 && rma < rmbb)) begin
                  result_q <= {3'b000, rem_input_a}; st <= ST_SPECIAL;   // remainder = rem_input_a, Q=0
                end else begin
'''
    after='''                // Exponents and significands must describe the same value.
                // The old exponent-only adjustment mis-scaled subnormal inputs.
                if (rea == 15'd0) rma = rma << rem_clz64(rma);
                if (rebe == 15'd0) rmbb = rmbb << rem_clz64(rmbb);
                rexpd = rea_a - reb_a;
                if (rexpd < 0 || (rexpd==0 && rma < rmbb)) begin
                  // FPREM truncates Q to zero here. FPREM1 instead needs Q=1
                  // when |A/B| > 1/2; exactly 1/2 still selects even Q=0.
                  if (prem1 && ((rexpd == 0) ||
                      (rexpd == -17'sd1 && rma > rmbb))) begin
                    S <= {16'd0, rma};
                    rmb <= rmbb;
                    reb <= (rexpd == -17'sd1) ? rea_a : reb_a;
                    rc2 <= 1'b0;
                    rsmall_half <= (rexpd == -17'sd1);
                    // qacc is already cleared in IDLE. Reuse the exact
                    // remainder subtract/normalizer rather than add a datapath.
                    st <= ST_RNORM;
                  end else begin
                    result_q <= {3'b000, rem_input_a}; st <= ST_SPECIAL;
                  end
                end else begin
'''
    text=once(text,before,after)
    text=once(text,"if (rexpd < 64) begin nb = rexpd[6:0];               ebe = $signed({2'b0,rebe}); rc2<=1'b0; end\n",
        "if (rexpd < 64) begin nb = rexpd[6:0];               ebe = reb_a; rc2<=1'b0; end\n")
    text=once(text,"else            begin nb = 7'd32 + {2'b0,rexpd[4:0]}; ebe = $signed({2'b0,rebe}) + (rexpd - {10'd0,nb}); rc2<=1'b1; end\n",
        "else            begin nb = 7'd32 + {2'b0,rexpd[4:0]}; ebe = reb_a + (rexpd - {10'd0,nb}); rc2<=1'b1; end\n")
    text=once(text,'          logic [63:0] r, q_eff, rrem; logic s_eff; logic [64:0] two_r; logic rndup;\n',
        '          logic [63:0] r, q_eff, rrem; logic s_eff; logic [64:0] two_r, rsub; logic rndup;\n')
    text=once(text,'''          rndup = rprem1 && !rc2 &&
                  ((two_r > {1'b0, rmb}) || ((two_r == {1'b0, rmb}) && qacc[0]));
          if (rndup) begin r = rmb - rrem; s_eff = ~rsa; q_eff = qacc[63:0] + 64'd1; end
''','''          rndup = rsmall_half || (rprem1 && !rc2 &&
                  ((two_r > {1'b0, rmb}) || ((two_r == {1'b0, rmb}) && qacc[0])));
          // For gap -1, use A's exponent: B's significand is doubled. The
          // admission test guarantees 0 < 2*mb-ma < mb, so 64 result bits suffice.
          rsub = (rsmall_half ? {rmb, 1'b0} : {1'b0, rmb}) - {1'b0, rrem};
          if (rndup) begin r = rsub[63:0]; s_eff = ~rsa; q_eff = qacc[63:0] + 64'd1; end
''')
    return text
