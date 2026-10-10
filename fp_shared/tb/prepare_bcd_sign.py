"""Preserve packed-decimal negative zero in iterative and combinational paths.

Legal 18-digit magnitudes fit exactly in signed int64. Convert the positive
magnitude, then attach the original sign (also when magnitude is zero). This
removes the unnecessary sign-controlled integer negation; no new cycle/state.
"""

def replace_once(text, old, new):
    if text.count(old)!=1:
        raise ValueError('missing, ambiguous or already repaired BCD sign conversion')
    return text.replace(old,new)

def engine(text):
    old=("          automatic logic signed [63:0] sval = sign_q ? -$signed(mag) : $signed(mag);\n"
         "          result_q <= fx_from_int(sval, 2'b11);   // FBLD: extended (PC follow-up)\n")
    new=("          automatic logic [79:0] magnitude_fp = fx_from_int($signed(mag), 2'b11);\n"
         "          // P54 FBLD preserves the packed sign, including negative zero.\n"
         "          result_q <= {sign_q, magnitude_fp[78:0]};\n")
    return replace_once(text,old,new)

def package(text):
    start=text.find('  function automatic logic [79:0] fx_bcd_to_fx(')
    end=text.find('  endfunction',start)
    if start<0 or end<0: raise ValueError('missing BCD conversion function')
    block=text[start:end]
    block=replace_once(block,'    logic signed [63:0] sval;', '    logic [79:0]       magnitude_fp;')
    block=replace_once(block,
        "      sval = bcd[79] ? -$signed(mag) : $signed(mag);                     // byte9 bit7 = sign\n"
        "      fx_bcd_to_fx = fx_from_int(sval, 2'b11);   // FBLD: extended (PC follow-up; not Quake-hot)\n",
        "      magnitude_fp = fx_from_int($signed(mag), 2'b11);\n"
        "      // Conversion is exact; integer zero must not discard the BCD sign.\n"
        "      fx_bcd_to_fx = {bcd[79], magnitude_fp[78:0]};\n")
    return replace_once(text,text[start:end],block)
