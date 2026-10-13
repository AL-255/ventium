"""Private exact V-only capture cofactor; no change to immediate return.

For dual-load pairing, a V-only saved-window return excludes every bank
capture owner. Do not make bank-hit eligibility depend on its late validity.
Two-lane independent requests retain the original immediate-return priority.
"""
import hashlib
import re

PARENT = 'd565f12a984a4e83c8816a0214705999033a2c0906ad66f44f27d5b117b4d4f8'
OLD = '&& !((lane == 1) && pair_now_valid)'
NEW = '''// A V-only saved-window return has a current read owner. It
                            // excludes free banks, a fresh U capture (saved line),
                            // a prime (!c_req), and a store (c_we). Legacy overlap
                            // excludes V-only requests under DUAL_LOAD_PAIR.
                            // Preserve immediate priority for standalone two-lane
                            // requests. The immediate return itself is unchanged.
                            && !((lane == 1) &&
`ifdef VEN_P54_DUAL_LOAD_PAIR
                                 pair_req_valid[0] &&
`endif
                                 pair_now_valid)'''


def equation(source):
    rows = re.findall(r'    assign pair_hit\[lane\] =.*?;\n', source, re.S)
    if len(rows) != 1 or rows[0].count(OLD) != 1:
        raise ValueError('pair-now capture equation drift')
    return rows[0]


def witness(old):
    return '''`ifndef SYNTHESIS
    logic pair_hit_before_now_cut;
''' + old.replace('pair_hit[lane]', 'pair_hit_before_now_cut') + '''    always_ff @(posedge clk) if (rst_n)
      assert (pair_hit[lane] === pair_hit_before_now_cut)
        else $fatal(1,"PAIR-NOW-CAPTURE: changed bank hit lane=%0d",lane);
`endif
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('pair-now capture parent drift/reapplication')
    old = equation(source)
    return source.replace(old, old.replace(OLD, NEW)+witness(old))
