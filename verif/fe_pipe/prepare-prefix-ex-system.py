#!/usr/bin/env python3
"""Narrow protected-client register-successor prefix/last-EX overlap."""
import argparse
import hashlib
import json
from pathlib import Path

FLAG = 'VEN_P54_PREFIX_EX_SYSTEM'
TARGET = 'rtl/core/core_prefix_ex_chain.svh'
OLD = '''    !sys_mode && !soc_en && !cosim_en && !def16 && !paging_on && !smm_active &&
    (fbase == 32'd0) && !fold_pending_r &&'''
NEW = '''`ifdef VEN_P54_PREFIX_EX_SYSTEM
    // Only a register successor: no EA, translation, memory fault, or
    // precommit source value is captured. EX reads its operands after old WB.
    // Keep the existing exact prefix grammar and EXT->EXT veto below.
    !d_mem_read && !d_mem_write && !def16 && !smm_active &&
    ((!sys_mode && !soc_en && !cosim_en && !paging_on && (fbase==32'd0)) ||
     (sys_mode && sys_fp_ok && !real_mode && !v86 && cs_d)) &&
    // The old instruction already owns this executable page/context. Never
    // borrow resident bytes on another page or beyond the live CS limit.
    (p54_prefix_ex_flin[31:12] == flin[31:12]) &&
    ({1'b0,next_eip} + {29'd0,d_len} - 33'd1 <= {1'b0,seg_limit[SG_CS]}) &&
    !irq_shadow && !intr && !nmi && !smi_pending && !nmi_pending &&
    !fold_pending_r &&
`else
''' + OLD + '''
`endif'''


def transform(text):
    if FLAG in text or text.count(OLD) != 1:
        raise ValueError('already applied or invalid context anchor')
    return text.replace(OLD, NEW)


def prepare(source, out):
    source = source.resolve(strict=True); out = out.resolve()
    if source == out:
        raise ValueError('private output must differ')
    original = source.read_bytes()
    with out.open('xb') as stream:
        stream.write(transform(original.decode()).encode())
    assert source.read_bytes() == original
    return dict(source=str(source), source_sha256=hashlib.sha256(original).hexdigest(),
                candidate=str(out), candidate_sha256=hashlib.sha256(out.read_bytes()).hexdigest(),
                gameplay_ipc=None, standard_suite=False, production_changed=False)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    print(json.dumps(prepare(args.source, args.out), indent=2))
