"""Prepare demand-fetch width without late request authorization in its payload.

Exact-parent private experiment. The request, header-fault, translation, page
clip and byte-commit equations remain unchanged. No wider issued fetch, new
register, bubble, guessed instruction length or disabled fast path is allowed.
"""
import hashlib

FILE = 'rtl/core/core.sv'
PARENT = 'a26a7dc82d8ab0049bece36548373e57cd71b64547c44c02e2356bd7aa1f14ce'
START = '  // Separate the byte-valid producer from the decoder-consuming beat shaper:\n'
END = '\n  // This tiny authorization cache is independent of the shared lookup port:'
OLD = "    sfetch_demand_size = 3'd0;\n    if (sfetch_demand_req) begin\n"
NEW = '''    // Prepare the byte-count payload independently of its request. In the
    // interior-16 profile it is four bytes without a decoder/header-fault path.
    // sfetch_demand_req still exclusively authorizes the fetch and translation;
    // the unchanged page clip and exact boundary count apply to every beat.
    // An inactive payload may differ, but must not create a bus/fault/commit.
    begin
'''


def block(source):
    if source.count(START) != 1 or source.count(END) != 1:
        raise ValueError('ambiguous demand-width block')
    return source[source.index(START):source.index(END)]


def shadow(source):
    original = block(source).replace('sfetch_demand_size', 'sfetch_size_ref')
    return '''
`ifndef SYNTHESIS
  // Keep the complete original width expression as a passive reference.
  logic [2:0] sfetch_size_ref;
'''+original+'''
  always_ff @(posedge clk) if (rst_n) begin
    if (sfetch_demand_req) begin
      assert (sfetch_demand_size === sfetch_size_ref)
        else $fatal(1, "DEMAND-SIZE-PAYLOAD: issued width changed");
      assert (sfetch_demand_size >= 3'd1 && sfetch_demand_size <= 3'd4 &&
              ({1'b0,sfetch_demand_addr[11:0]} + {10'd0,sfetch_demand_size}
               <= 13'h1000))
        else $fatal(1, "DEMAND-SIZE-PAYLOAD: invalid issued page extent");
    end
    if ((state == S_FETCH) && sfetch_boundary && !sfetch_demand_req) begin
      assert (!bd_req && !mem_req && !fe_translatable && !xlate_miss &&
              !fe_xlate_pend && !perm_fault && !cs_fetch_fault && !fx_start)
        else $fatal(1, "DEMAND-SIZE-PAYLOAD: inactive width acquired authority");
    end
  end
`endif
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('demand-width predecessor drift/reapplication')
    original = block(source)
    if original.count(OLD) != 1:
        raise ValueError('ambiguous demand-width gate')
    replacement = original.replace(OLD, NEW)
    if replacement.replace(NEW, OLD) != original:
        raise ValueError('non-reversible width edit')
    return source.replace(original, replacement+shadow(source))
