"""Exact-parent shared-SRT special classification and architectural abort."""
import hashlib

PARENTS = {
    'rtl/fpu/fpu_srt_div.sv': 'f9fd5d2f24be3d43a5aa4d9ee9476058e953504765fca90de6ca5a45b4f8d3b9',
    'fp_shared/ven_fp_top.sv': '8f7749836fd2f7c744c450eecc63d3539baf447998a3e00939577cef1705b7e2',
}


def once(text, old, new):
    if text.count(old) != 1: raise ValueError('FPREM exception anchor drift: '+old[:60])
    return text.replace(old, new)


def transform(text, name):
    if hashlib.sha256(text.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('FPREM exception parent drift or repeated application: '+name)
    if name.endswith('fpu_srt_div.sv'):
        text = once(text, '  // Six binary decisions, rather than a 64-entry first-match chain.\n', '''  // Unsupported x80 encodings precede NaNs; a signaling operand raises IE
  // even when the other operand supplies the quiet NaN result.
  function automatic logic rem_unsupported(input logic [79:0] v);
    return (v[78:64] != 15'd0) && !v[63];
  endfunction
  function automatic logic rem_snan(input logic [79:0] v);
    return rem_is_nan(v) && !v[62];
  endfunction
  function automatic logic [79:0] rem_canonical(input logic [79:0] v);
    // Pseudo-denormals are accepted, raise DE at the architectural shell,
    // and become canonical normals even when quotient zero bypasses SRT.
    return ((v[78:64] == 15'd0) && v[63]) ? {v[79], 15'd1, v[63:0]} : v;
  endfunction
  function automatic logic [79:0] rem_nan_result(input logic [79:0] x, y);
    logic xn, yn, xs, ys;
    xn = rem_is_nan(x); yn = rem_is_nan(y);
    xs = rem_snan(x); ys = rem_snan(y);
    if (!yn || (xn && !xs && ys)) return rem_quiet(x);
    if (!xn || (yn && !ys && xs)) return rem_quiet(y);
    // Same NaN kind: greatest significand; equal payload prefers positive.
    if (x[63:0] > y[63:0]) return rem_quiet(x);
    if (x[63:0] < y[63:0]) return rem_quiet(y);
    return rem_quiet(x[79] ? y : x);
  endfunction
  // Six binary decisions, rather than a 64-entry first-match chain.
''')
        text = once(text, '''              if (rem_is_nan(rem_input_a) || rem_is_nan(rem_input_b)) begin
                result_q <= {3'b000, (rem_is_nan(rem_input_a) ? rem_quiet(rem_input_a) : rem_quiet(rem_input_b))};
                st <= ST_SPECIAL;
''', '''              if (rem_unsupported(rem_input_a) || rem_unsupported(rem_input_b)) begin
                result_q <= {3'b000, RQNAN_INDEF}; rem_ie <= 1'b1; st <= ST_SPECIAL;
              end else if (rem_is_nan(rem_input_a) || rem_is_nan(rem_input_b)) begin
                result_q <= {3'b000, rem_nan_result(rem_input_a, rem_input_b)};
                rem_ie <= rem_snan(rem_input_a) || rem_snan(rem_input_b);
                st <= ST_SPECIAL;
''')
        # Both zero-quotient bypasses must canonicalize pseudo-denormal A.
        old = "result_q <= {3'b000, rem_input_a};"
        if text.count(old) != 2: raise ValueError('FPREM zero-quotient bypass drift')
        text = text.replace(old, "result_q <= {3'b000, rem_canonical(rem_input_a)};")
    else:
        text = once(text, '  logic        srt_rem_c2, srt_rem_ie;\n', '''  logic        srt_rem_c2, srt_rem_ie;
  logic        srt_rem_denormal, srt_rem_abort;
  // TOP_SRT serializes architectural stack/CW changes. Use fixed ST(1),
  // never sti_data: an unaccepted live command can change its read index.
  assign srt_rem_denormal =
      (pending_op inside {FX_FPREM, FX_FPREM1}) && !srt_rem_ie &&
      !fx_is_nan(st0_data) && !fx_is_nan(st_flat_o[159:80]) &&
      (fx_is_denormal(st0_data) || fx_is_denormal(st_flat_o[159:80]));
  assign srt_rem_abort = (srt_rem_ie && !fctrl_o[0]) ||
                         (srt_rem_denormal && !fctrl_o[1]);
''')
        text = once(text, '''        c_status_data = fstat_o & ~16'h4700;
        if (srt_rem_ie)
''', '''        c_write = !srt_rem_abort;
        c_status_data = (fstat_o & ~16'h4700) |
                        (srt_rem_denormal ? 16'h0002 : 16'h0000);
        if (srt_rem_ie)
''')
        text = once(text, '''            FX_FSQRT, FX_FRNDINT, FX_FSCALE, FX_FPREM, FX_FPREM1,
''', '''            FX_FPREM, FX_FPREM1: begin
              c_write = 1'b1;
              c_write_idx = 3'd0;
              c_write_data = QNAN_INDEF;
              c_status_data[10] = 1'b0;
            end
            FX_FSQRT, FX_FRNDINT, FX_FSCALE,
''')
        text = once(text, '''        c_pop = 2'd0;
      end else begin
        c_status_data = f_arith_fstat(fstat_o,
''', '''        // An operand abort commits no numeric result or quotient. Retain
        // the previous C0/C2/C3, clear C1, and merge only the raised exception.
        // This also matches native x87 for the undefined abort condition bits.
        if (srt_rem_abort)
          c_status_data = (fstat_o & ~16'h0200) |
                          (srt_rem_ie ? 16'h0001 : 16'h0002);
        c_pop = 2'd0;
      end else begin
        c_status_data = f_arith_fstat(fstat_o,
''')
    return text
