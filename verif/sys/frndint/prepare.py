"""Isolated FRNDINT repair on the exact, qualified environment-store parent."""
import hashlib

PARENTS = {
    'rtl/fpu/fpu_x87_pkg.sv': 'ae0b7bdb71e8c3450a7704a70c4742cf04eba4cc17c7e82aba40361855c59a01',
    'fp_shared/ven_fp_misc.sv': '4ac4e9d37dc57f6af3fd2babe41a13df5069a2797ab7b6dd8b811ff511fe0161',
    'fp_shared/ven_fp_top.sv': '9034b0b60dbd6f0170e788a06d20b78bc6a78111a63d7c5adef3b8219083193a',
}

QUANTIZER = '''  // Shared finite |v| < 2^63 integer quantizer. Keep the unsigned
  // magnitude and rounding event: FRNDINT is not a signed-integer conversion.
  // Returns {rounded_up, inexact, magnitude[63:0]}. FIST/FSCALE retain their
  // existing signed range policy around this same quantizer.
  function automatic logic [65:0] fx_round_int_mag(input logic [79:0] v,
                                                  input logic [1:0] rc);
    logic [63:0] whole, lost, half, m;
    logic up;
    int shift;
    begin
      m = fx_man(v);
      shift = 63 - fx_uexp(v);
      whole = m >> shift;
      lost = m & ((64'd1 << shift) - 64'd1);
      half = (shift > 64) ? 64'hffffffffffffffff : (64'd1 << (shift-1));
      up = fx_dir_up(lost, half, whole[0], fx_sign(v), rc);
      return {up, (lost != 64'd0), whole + {63'd0, up}};
    end
  endfunction

'''


def replace(s, old, new, count=1):
    if s.count(old) != count: raise ValueError('ambiguous FRNDINT anchor: '+old[:90])
    return s.replace(old,new)


def transform(s, name):
    if hashlib.sha256(s.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('FRNDINT source drift/reapplication: '+name)
    if name.endswith('fpu_x87_pkg.sv'):
        start=s.index('  // floatx80 -> signed integer with exception reporting,')
        s=s[:start]+QUANTIZER+s[start:]
        start=s.index('  function automatic logic [65:0] fx_to_int_ex(')
        end=s.index('\n  endfunction',start)
        f=s[start:end]
        a=f.index('    // P0-13 FP area:'); b=f.index('    int          shift;',a)
        f=f[:a]+"    logic [65:0] quantized;\n"+f[b:]
        f=replace(f,'logic        inex, ovf, up;','logic        inex, ovf;')
        f=replace(f,'else mag = m;                         // exactly 2^63 (m=0x8000..)','')
        a=f.index('        logic [63:0] ish;');b=f.index('\n      end\n      // width range check',a)
        f=f[:a]+'''        quantized = fx_round_int_mag(v, rc);
        inex = quantized[64];
        sval = s ? -$signed(quantized[63:0]) : $signed(quantized[63:0]);'''+f[b:]
        s=s[:start]+f+s[end:]
    elif name.endswith('ven_fp_misc.sv'):
        s=replace(s,'          automatic logic [65:0] ri;','''          automatic logic [65:0] ri;
          automatic logic [79:0] integral;''')
        s=replace(s,"          ri  = 66'd0;","          ri  = 66'd0;\n          integral = 80'd0;")
        start=s.index('            FX_FRNDINT: begin');end=s.index('\n            FX_FSCALE:',start)
        s=s[:start]+'''            FX_FRNDINT: begin
              if ((fx_exp(a_q) != 15'd0) && !a_q[63]) begin
                value <= 80'hffffc000000000000000; // unsupported encoding
                flag_ie <= 1'b1;
              end else if ((fx_exp(a_q) == 15'h7fff) && !a_q[62] &&
                           (a_q[61:0] != 62'd0)) begin
                value <= {a_q[79:63], 1'b1, a_q[61:0]}; // quiet SNaN
                flag_ie <= 1'b1;
              end else if (fx_is_inf_nan(a_q) || fx_is_zero(a_q) ||
                           (fx_uexp(a_q) >= 32'sd63)) begin
                value <= a_q;
              end else begin
                ri = fx_round_int_mag(a_q, rc_q);
                // All rounded magnitudes fit <=2^63. The signed converter's
                // absolute value handles the 2^63 bit pattern; restore the
                // ORIGINAL sign, including negative zero. FRNDINT ignores PC.
                integral = fx_from_int($signed(ri[63:0]), 2'b11);
                value <= {fx_sign(a_q), integral[78:0]};
                flag_pe <= ri[64];
                rounded_up <= ri[65];
              end
            end
''' + s[end:]
    else:
        s=replace(s,'  logic        misc_commit_ue, misc_commit_pe;', '''  logic        misc_commit_ue, misc_commit_pe;
  logic        misc_frnd_denormal, misc_frnd_abort;
  // ST0 and CW cannot change while the serialized misc owner is pending.
  // No live command input participates in these exception/commit decisions.
  assign misc_frnd_denormal = (pending_op == FX_FRNDINT) &&
                             fx_is_denormal(st0_data) && !misc_ie;
  assign misc_frnd_abort = (pending_op == FX_FRNDINT) &&
      ((misc_ie && !fctrl_o[0]) || (misc_frnd_denormal && !fctrl_o[1]));''')
        s=replace(s,'assign misc_commit_pe = misc_pe && !misc_fst_range_block;',
                    'assign misc_commit_pe = misc_pe && !misc_fst_range_block && !misc_frnd_abort;')
        start=s.index('    if ((top_state == TOP_MISC) && misc_done) begin')
        end=s.index('\n    if ((top_state == TOP_BCD_LOAD)',start)
        f=s[start:end]
        f=replace(f,"c_write      = 1'b1;","c_write      = !misc_frnd_abort;")
        f=replace(f,'(pending_op inside {FX_FST_M32, FX_FST_M64, FX_FST_M80})) begin',
                    '(pending_op inside {FX_FST_M32, FX_FST_M64, FX_FST_M80, FX_FRNDINT})) begin')
        f=replace(f,"(misc_ie ? 16'h0001 : 16'h0000) |", "(misc_ie ? 16'h0001 : 16'h0000) |\n                        (misc_frnd_denormal ? 16'h0002 : 16'h0000) |")
        f=replace(f,'        // Only the completing FST owner consumes the registered bit.\n        // Exact m80 stores clear C1; other misc opcode semantics are separate.',
                    '        // Consume only the completing owner: exact FRNDINT also clears\n        // stale C1. Invalid/denormal aborts do not round or overwrite ST0.')
        f=replace(f,'          c_status_data[9] = misc_rounded_up && !misc_fst_range_block;',
                    '          c_status_data[9] = misc_rounded_up && !misc_fst_range_block;\n        if (pending_op == FX_FRNDINT)\n          c_status_data[9] = misc_rounded_up && !misc_frnd_abort;')
        s=s[:start]+f+s[end:]
    return s
