#!/usr/bin/env python3
"""Private resident-read hint during an unchanged paid P54 AGI clock."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

HERE=Path(__file__).resolve().parent
FLAG='VEN_RAW_AGI_PRIME'
TARGET='rtl/core/core_mem_chain.svh'
LEAF='rtl/core/core_agi_resident_prime.svh'
CHANGES={
    '  `include "core_ref_operand_prime.svh"':
    '  `include "core_ref_operand_prime.svh"\n  `include "core_agi_resident_prime.svh"',
    '  assign mc_query_seg = ref_prime_select ? d_seg :':
    '  assign mc_query_seg = agi_prime_select ? pipe_mem_seg : ref_prime_select ? d_seg :',
    '  assign mc_query_ea = ref_prime_select ? d_ea :':
    '  assign mc_query_ea = agi_prime_select ? pipe_load_addr : ref_prime_select ? d_ea :',
    '    mc_prepare_ok = !ref_prime_select && mc_boundary_ok &&':
    '    mc_prepare_ok = !agi_prime_select && !ref_prime_select && mc_boundary_ok &&',
    '  assign mem_next_req = ref_prime_offer ||':
    '  assign mem_next_req = agi_prime_offer || ref_prime_offer ||',
    '  assign mem_next_commit = ref_prime_commit ||':
    '  assign mem_next_commit = agi_prime_commit || ref_prime_commit ||',
    '  assign mem_next_addr = (ref_prime_select || mc_prime_offer)':
    '  assign mem_next_addr = (agi_prime_select || ref_prime_select || mc_prime_offer)',
    '  assign mem_next_wstrb = ref_prime_select ? ref_prime_strb :':
    '  assign mem_next_wstrb = agi_prime_select ? ((agi_prime_width == 3\'d1) ? 4\'h1 : 4\'hf) :\n'
    '      ref_prime_select ? ref_prime_strb :',
}


def transform(text):
    if 'core_agi_resident_prime' in text:raise ValueError('already applied')
    for old,new in CHANGES.items():
        if text.count(old)!=1:raise ValueError('missing/ambiguous anchor: '+old)
        text=text.replace(old,new)
    return text


def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()


def prepare(source,output):
    source,output=source.resolve(strict=True),output.resolve()
    if output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError('source/output must be disjoint')
    pins={str(p.relative_to(source)):sha(p) for p in source.rglob('*') if p.is_file()}
    if LEAF in pins:raise ValueError('existing AGI prime leaf')
    changed=transform((source/TARGET).read_text())
    shutil.copytree(source,output)
    (output/TARGET).write_text(changed)
    shutil.copyfile(HERE/'core_agi_resident_prime.svh',output/LEAF)
    actual={str(p.relative_to(output)):sha(p) for p in output.rglob('*') if p.is_file()}
    assert set(actual)==set(pins)|{LEAF}
    assert [p for p in pins if pins[p]!=actual[p]]==[TARGET]
    assert all(sha(source/p)==h for p,h in pins.items())
    return dict(parent=str(source),parent_pins=pins,candidate_pins=actual,
                added_define=FLAG,production=False,standard_suite=False,gameplay_ipc=None)


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();result=prepare(args.source,args.out)
    with (args.out/'agi-resident-prime-inputs.json').open('x') as f:json.dump(result,f,indent=2)
