"""Clear C1 for accepted direct loads, before the existing stack-fault override.

Reuse the direct push commit predicate: no new arithmetic, cycle or state.
This repairs the shared-FP implementation, not the legacy writeback backend.
"""

def transform(text):
    anchor = ('      // Stack faults override the ordinary issue path.  This mirrors the\n'
              '      // proven writeback matrix: IE|SF are unconditional, C1 distinguishes\n')
    marker = '      // P54 table 6-4: direct FLD/FILD/constant loads clear C1.\n'
    if text.count(anchor) != 1 or marker in text:
        raise ValueError('missing, ambiguous or already repaired shared-load commit')
    return text.replace(anchor, marker +
        '      // Only direct loads assert c_push here. Deferred arithmetic and\n'
        '      // transcendental pushes commit below, under their own owner.\n'
        '      // Keep this BEFORE #IS: a full-stack push must still report C1=1.\n'
        "      if (c_push) begin\n"
        "        c_status = 1'b1;\n"
        "        c_status_data[9] = 1'b0;\n"
        "      end\n\n" + anchor)
