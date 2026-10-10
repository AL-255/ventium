"""Backport the numeric SRT exponent fix without changing C1 or scheduling.

The independently rounded PC24/53 packer must receive the unrounded floor
exponent. A carry in the separate PC64 path must not be applied twice. Also
test a floor borrow before replacing its significand with all ones.

Only combinational rounding expressions change. Existing ports, registers,
special cases, recurrence, completion timing and C1 semantics are retained.
"""

DECL = '  int                  msb, extra;'
SCAN = '    for (int i=127; i>=0; i--) if (uq[i]) begin msb=i; break; end'
OLD = '''    keepf   = uq >> extra;                            // floor 64-bit window (unrounded)
    if (resid_neg) begin                             // SRT over-shot by < 1 ULP
      keepf = keepf - 128'd1;
      if (!keepf[63]) keepf = {64'd0, 64'hFFFFFFFFFFFFFFFF};  // borrowed across pow2
    end
    stickyp = (remv != 128'd0) || rs_pos || resid_neg;        // any residual below floor
    sigp    = keepf << 64;                            // window MSB (bit63) -> bit127
    // weight of keepf's MSB (bit63) == weight of uq bit `msb` (the floor window top):
    // (msb - SH) + (ua-ub), SH=70 (div) / 72 (sqrt). resid_neg's pow2-borrow drops
    // the window MSB one position, but fx_round_pack_f re-finds the MSB of sigp and
    // uses the passed weight as ITS top bit's exponent, so pass the floor MSB weight.
    ep      = ($signed(msb) - round_sh_q) + (ua - ub);
    if (resid_neg && !keepf[63]) ep = ep - 32'sd1;    // borrow crossed a power of two'''
NEW = '''    keepf   = uq >> extra;                            // floor 64-bit window (unrounded)
    ep      = ($signed(floor_msb) - round_sh_q) + (ua - ub);
    if (resid_neg) begin                             // SRT over-shot by < 1 ULP
      keepf = keepf - 128'd1;
      if (!keepf[63]) begin
        keepf = {64'd0, 64'hFFFFFFFFFFFFFFFF};         // borrowed across pow2
        ep = ep - 32'sd1;
      end
    end
    stickyp = (remv != 128'd0) || rs_pos || resid_neg;        // any residual below floor
    sigp    = keepf << 64;                            // window MSB (bit63) -> bit127
    // The packer owns its rounding carry/borrow. It must receive the FLOOR's
    // exponent, not msb after PC64 rounding; otherwise an inline carry is
    // counted twice at PC24/53. Apply a floor borrow before replacing its MSB.'''


def transform(source):
    if 'floor_msb' in source:
        raise ValueError('SRT floor exponent repair already present')
    for anchor in (DECL, SCAN, OLD):
        if source.count(anchor) != 1:
            raise ValueError('missing/ambiguous SRT floor anchor: '+anchor)
    return source.replace(DECL, '  int                  msb, floor_msb, extra;').replace(
        SCAN, SCAN+'\n    floor_msb = msb;                              // before the independent PC64 round').replace(OLD, NEW)
