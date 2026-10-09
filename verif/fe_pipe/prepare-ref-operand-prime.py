#!/usr/bin/env python3
"""Private reference-operand resident prime; no production-default changes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
FLAG = 'VEN_REF_OPERAND_PRIME'
TARGET = 'rtl/core/core_mem_chain.svh'
LEAF = 'rtl/core/core_ref_operand_prime.svh'
CHANGES = {
    '  assign mc_query_seg = mc_query_u.mem_ss':
    '  `include "core_ref_operand_prime.svh"\n\n'
    '  assign mc_query_seg = ref_prime_select ? d_seg : mc_query_u.mem_ss',
    '  assign mc_query_ea = (mc_query_u.mem_base_en':
    '  assign mc_query_ea = ref_prime_select ? d_ea : (mc_query_u.mem_base_en',
    '    mc_prepare_ok = mc_boundary_ok &&':
    '    mc_prepare_ok = !ref_prime_select && mc_boundary_ok &&',
    '  assign mem_next_req = mc_offer || mc_prime_offer;':
    '  assign mem_next_req = ref_prime_offer || mc_offer || mc_prime_offer;',
    '  assign mem_next_commit = (mc_offer ||':
    '  assign mem_next_commit = ref_prime_commit || ((mc_offer ||',
    '      (pipe_int_commit || (mc_fp_self_prime && fp_shared_mem_admit));':
    '      (pipe_int_commit || (mc_fp_self_prime && fp_shared_mem_admit)));',
    '  assign mem_next_addr = mc_prime_offer ? mc_query_phys : mc_phys_q;':
    '  assign mem_next_addr = (ref_prime_select || mc_prime_offer) ? mc_query_phys : mc_phys_q;',
    '  assign mem_next_wstrb = (mc_prime_offer ? mc_query_u.w8 : mc_u_q.w8)':
    '  assign mem_next_wstrb = ref_prime_select ? ref_prime_strb :\n'
    '      (mc_prime_offer ? mc_query_u.w8 : mc_u_q.w8)',
}


def transform(text):
    if 'core_ref_operand_prime' in text:
        raise ValueError('reference operand prime already applied')
    for old, new in CHANGES.items():
        if text.count(old) != 1:
            raise ValueError(f'expected exactly one anchor: {old!r}')
        text = text.replace(old, new)
    return text


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def prepare(source, output):
    source, output = source.resolve(strict=True), output.resolve()
    if output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError('source/output must be disjoint')
    pins = {str(p.relative_to(source)): sha(p) for p in source.rglob('*') if p.is_file()}
    if LEAF in pins:
        raise ValueError('unexpected existing reference-prime leaf')
    changed = transform((source/TARGET).read_text())
    shutil.copytree(source, output)
    (output/TARGET).write_text(changed)
    shutil.copyfile(HERE/'core_ref_operand_prime.svh', output/LEAF)
    actual = {str(p.relative_to(output)): sha(p) for p in output.rglob('*') if p.is_file()}
    assert set(actual) == set(pins) | {LEAF}
    assert [p for p in pins if pins[p] != actual[p]] == [TARGET]
    assert all(sha(source/p) == h for p,h in pins.items())
    return dict(parent=str(source),parent_pins=pins,candidate_pins=actual,
                added_define=FLAG,production=False,standard_suite=False,gameplay_ipc=None)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    result=prepare(args.source,args.out)
    with (args.out/'ref-operand-prime-inputs.json').open('x') as f:
        json.dump(result,f,indent=2)
