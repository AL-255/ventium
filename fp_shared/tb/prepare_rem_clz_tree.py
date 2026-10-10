#!/usr/bin/env python3
"""Private default-off balanced replacement of the SRT remainder CLZ only."""

FLAG = 'VEN_SRT_REM_CLZ_TREE'
OLD = """  function automatic logic [6:0]  rem_clz64(input logic [63:0] x);
    logic [6:0] n; n = 7'd64;
    for (int i=63;i>=0;i--) if (x[i] && n==7'd64) n = 7'd63 - i[6:0];
    return n; endfunction"""
NEW = """  function automatic logic [6:0]  rem_clz64(input logic [63:0] x);
    logic [63:0] part;
    logic [6:0] n;
    part = x;
    n = 7'd0;
    // Procedural if preserves the old priority loop's treatment of X/Z:
    // only a known one selects a half. A half with X/Z but no one is skipped.
    // Six decisions replace the serial found/not-found dependency chain.
    if (|part[63:32]) part = part;
    else begin part = part << 32; n[5] = 1'b1; end
    if (|part[63:48]) part = part;
    else begin part = part << 16; n[4] = 1'b1; end
    if (|part[63:56]) part = part;
    else begin part = part << 8; n[3] = 1'b1; end
    if (|part[63:60]) part = part;
    else begin part = part << 4; n[2] = 1'b1; end
    if (|part[63:62]) part = part;
    else begin part = part << 2; n[1] = 1'b1; end
    if (part[63]) n[0] = 1'b0;
    else n[0] = 1'b1;
    if (|x) return n;
    else return 7'd64;
  endfunction"""


def transform(source):
    if FLAG in source or source.count(OLD) != 1:
        raise ValueError('already applied or remainder CLZ source drift')
    # Do not substitute another sqrt/divide normalizer or alter its zero rule.
    # Two operand exponent adjustments and the final remainder normalizer.
    if source.count('rem_clz64(') != 4:
        raise ValueError('remainder CLZ caller closure changed')
    return source.replace(OLD, '`ifdef '+FLAG+'\n'+NEW+'\n`else\n'+OLD+'\n`endif')
