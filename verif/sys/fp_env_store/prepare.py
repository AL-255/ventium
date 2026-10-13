"""Encode 32-bit real/V86 x87 environment pointers, preserving protected mode.

Derives from the independently checked pointer-restore candidate. This only
changes four packed pointer words; no new register, state, port or transaction.
"""
import hashlib

PARENTS = {
    'fp_shared/ven_fp_top.sv': 'fe629f375a3e7a126a1ea7ae127987c91bcd256f4868ef65be0199c199f5040d',
}
BEFORE = """        {16'd0, fds_o},
        fdp_o,
        {5'd0, 11'd0, fcs_o},
        fip_o,
"""
AFTER = """        // Intel P5 Vol. 3 figure 6-7: real/V86 32-bit pointers are
        // split across words, unlike the protected-mode offset/selector pair.
        cmd_real_mode ? {4'd0, fdp_o[31:16], 12'd0} : {16'd0, fds_o},
        cmd_real_mode ? {16'd0, fdp_o[15:0]} : fdp_o,
        cmd_real_mode ? {4'd0, fip_o[31:16], 12'd0} : {5'd0, 11'd0, fcs_o},
        cmd_real_mode ? {16'd0, fip_o[15:0]} : fip_o,
"""


def transform(source, name):
    if hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('FP environment store source drift/reapplication: '+name)
    if source.count(BEFORE) != 1:
        raise ValueError('FP environment store ambiguous anchor: '+name)
    return source.replace(BEFORE, AFTER)
