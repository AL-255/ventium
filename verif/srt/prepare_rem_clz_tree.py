"""Balance the remainder setup CLZ without changing any sequential equation."""
import hashlib

PARENT = '4981be7041c2e67cca1b216ca486596bc327bd102f6e8278b172e669ee159c11'
OLD = '''  function automatic logic [6:0]  rem_clz64(input logic [63:0] x);
    logic [6:0] n; n = 7'd64;
    for (int i=63;i>=0;i--) if (x[i] && n==7'd64) n = 7'd63 - i[6:0];
    return n; endfunction
'''
NEW = '''  // Six binary decisions, rather than a 64-entry first-match chain.
  // Keep the all-zero result at 64; denormal exponent adjustment uses it.
  function automatic logic [6:0] rem_clz64(input logic [63:0] x);
    logic [31:0] w32;
    logic [15:0] w16;
    logic [7:0] w8;
    logic [3:0] w4;
    logic [1:0] w2;
    logic [5:0] n;
    n[5] = ~(|x[63:32]);
    w32 = n[5] ? x[31:0] : x[63:32];
    n[4] = ~(|w32[31:16]);
    w16 = n[4] ? w32[15:0] : w32[31:16];
    n[3] = ~(|w16[15:8]);
    w8 = n[3] ? w16[7:0] : w16[15:8];
    n[2] = ~(|w8[7:4]);
    w4 = n[2] ? w8[3:0] : w8[7:4];
    n[1] = ~(|w4[3:2]);
    w2 = n[1] ? w4[1:0] : w4[3:2];
    n[0] = ~w2[1];
    return (x == 64'd0) ? 7'd64 : {1'b0, n};
  endfunction
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT or source.count(OLD) != 1:
        raise ValueError('SRT source drift')
    changed = source.replace(OLD, NEW)
    if changed.replace(NEW, OLD) != source:
        raise ValueError('non-reversible CLZ edit')
    return changed
