"""Rebase the tested shared-FPU repair onto the retained pre-metadata core."""
import hashlib
import prepare_remainder_underflow as leaf

CORE = 'rtl/core/core.sv'
PARENTS = dict(leaf.PARENTS, **{CORE:
    '238cd9f713cc6e84a6881cb5e06b8ff341a90cb428be8882b1f1b2d974491ac4'})


def transform(text, name):
    if name != CORE: return leaf.transform(text, name)
    if hashlib.sha256(text.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('retained underflow core parent drift/reapplication')
    # Same explicit legacy tie-off as the leaf experiment. No buffered
    # metadata decoder, semantic decoder change or new core bubble is inherited.
    return leaf.once(text, '    .prem1(eng_u_prem1), .a(eng_u_a),',
        "    // Legacy status integration is unchanged by the shared-FPU experiment.\n"
        "    .rem_underflow_mask(1'b1),\n    .prem1(eng_u_prem1), .a(eng_u_a),")
