"""Private, cycle-neutral cofactor of the staged fetch-size output mux.

Keep the exact page clip, including arbitrary/unreachable byte counts. No
request, owner, stage, trap, decoder or instruction-byte acceptance is changed.
"""
import hashlib

PARENT = '8d454c1ce275963da75354aca703701a4341b441031ae53f39e1fb911a365d0d'
FILE = 'rtl/core/core.sv'
OLD_SELECT = '''  assign sfetch_demand_size =
`ifdef VEN_SFETCH16_DEMAND
                             sfetch_interior16 ? sfetch_want_size :
`endif
                             sfetch_beat_size_q;
'''
HELPER = '''`ifdef VEN_SFETCH16_DEMAND
  // The selected interior arm already overrides want_size with four before
  // page clipping. Compute that cofactor directly: decoding the next demanded
  // byte count cannot affect this arm. Retain clipping even for arbitrary
  // valid-byte counts; do not rely on the reachable multiple-of-four invariant.
  logic [2:0] sfetch_interior_size;
  always_comb begin
    sfetch_interior_size = 3'd4;
    if ((sfetch_demand_addr[11:0] > 12'hffc) &&
        (sfetch_interior_size > 3'(13'h1000 - {1'b0,sfetch_demand_addr[11:0]})))
      sfetch_interior_size = 3'(13'h1000 - {1'b0,sfetch_demand_addr[11:0]});
  end
`endif
'''
NEW_SELECT = OLD_SELECT.replace('sfetch_interior16 ? sfetch_want_size :',
                                'sfetch_interior16 ? sfetch_interior_size :')


def want_block(source):
    begin = source.index('  always_comb begin\n    // Prepare the byte-count payload')
    end = source.index('  // Only true page/CS/IP boundaries', begin)
    return source[begin:end]


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('interior cofactor parent drift/reapplication')
    if source.count(OLD_SELECT) != 1:
        raise ValueError('fetch size selector drift')
    want = want_block(source)
    assert "if (sfetch_interior16) sfetch_want_size = 3'd4;" in want
    witness = '''`ifndef SYNTHESIS
  logic [2:0] sfetch_demand_size_before_interior_cut;
'''+OLD_SELECT.replace('assign sfetch_demand_size =',
                      'assign sfetch_demand_size_before_interior_cut =')+'''
  always_ff @(posedge clk) if (rst_n)
    assert (sfetch_demand_size === sfetch_demand_size_before_interior_cut)
      else $fatal(1,"SFETCH-INTERIOR-COFACTOR: changed size payload");
`endif
'''
    return source.replace(OLD_SELECT, HELPER+NEW_SELECT+witness, 1)
