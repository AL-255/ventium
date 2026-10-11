"""Balance the three SRT input-normalization searches; preserve every cycle.

This is an exact-source private derivative, not an edit to the live RTL.
Unlike remainder CLZ, these searches use zero shift when no bit is one.
"""
import hashlib

PARENT = 'f9ce70532446bbc7b991180a030bb319d50ba88a93deead1030ba3a73296461f'
ANCHOR = '  // ---- result --------------------------------------------------------------\n'
HELPER = '''  // Highest known-one search in six binary decisions. Procedural if,
  // rather than ?:, retains the old loop's treatment of X/Z test bits.
  // The original divide ka/kb defaults and sqrt cz default mean that an
  // all-zero (or no-known-one) mantissa must return ZERO, not 64.
  function automatic logic [5:0] srt_input_clz64(input logic [63:0] x);
    logic [31:0] w32;
    logic [15:0] w16;
    logic [7:0] w8;
    logic [3:0] w4;
    logic [1:0] w2;
    logic [5:0] n;
    n = 6'd0;
    if (|x[63:32]) w32 = x[63:32];
    else begin w32 = x[31:0]; n[5] = 1'b1; end
    if (|w32[31:16]) w16 = w32[31:16];
    else begin w16 = w32[15:0]; n[4] = 1'b1; end
    if (|w16[15:8]) w8 = w16[15:8];
    else begin w8 = w16[7:0]; n[3] = 1'b1; end
    if (|w8[7:4]) w4 = w8[7:4];
    else begin w4 = w8[3:0]; n[2] = 1'b1; end
    if (|w4[3:2]) w2 = w4[3:2];
    else begin w2 = w4[1:0]; n[1] = 1'b1; end
    if (w2[1]) n[0] = 1'b0;
    else n[0] = 1'b1;
    if (|x) return n;
    return 6'd0;
  endfunction

'''
EDITS = (
    ('for (int i=63; i>=0; i--) if (manr[i]) begin cz = 63 - i; break; end',
     "cz = int'(srt_input_clz64(manr));"),
    ('for (int i=63;i>=0;i--) if (ma_[i]) begin ka=i; break; end',
     "ka = 63 - int'(srt_input_clz64(ma_));"),
    ('for (int i=63;i>=0;i--) if (mb_[i]) begin kb=i; break; end',
     "kb = 63 - int'(srt_input_clz64(mb_));"),
)


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('SRT input-normalization parent drift')
    if source.count(ANCHOR) != 1 or 'srt_input_clz64' in source:
        raise ValueError('missing/ambiguous helper insertion point')
    result = source.replace(ANCHOR, HELPER + ANCHOR)
    for old, new in EDITS:
        if result.count(old) != 1:
            raise ValueError('missing/ambiguous normalization search')
        result = result.replace(old, new)
    reversed_source = result.replace(HELPER, '')
    for old, new in EDITS:
        reversed_source = reversed_source.replace(new, old)
    if reversed_source != source:
        raise ValueError('non-reversible normalization edit')
    return result
