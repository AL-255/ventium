#!/usr/bin/env python3
"""Do not inhibit prefix overlap for an architecturally masked raw INTR."""
import argparse,hashlib,json
from pathlib import Path

TARGET='rtl/core/core_prefix_ex_chain.svh'
OLD='''    !irq_shadow && !intr && !nmi && !smi_pending && !nmi_pending &&'''
NEW='''    // These older EXT/IMUL owners preserve IF. A raw INTR with IF=0 is
    // not deliverable at either boundary; it must not disable overlap until
    // a future instruction unmasks it. That instruction cannot chain here.
    // Still block a newly asserted deliverable pin before its pending latch.
    !irq_shadow && !(intr && eflags[9]) && !nmi && !smi_pending && !nmi_pending &&'''

def transform(text):
    if 'VEN_P54_PREFIX_EX_SYSTEM' not in text or text.count(OLD)!=1:
        raise ValueError('requires exactly the first protected-prefix proposal')
    return text.replace(OLD,NEW)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();src=a.source.resolve(strict=True);out=a.out.resolve()
    assert src!=out
    original=src.read_bytes();changed=transform(original.decode()).encode()
    with out.open('xb') as f:f.write(changed)
    assert src.read_bytes()==original
    print(json.dumps(dict(source=str(src),source_sha256=hashlib.sha256(original).hexdigest(),
        candidate=str(out),candidate_sha256=hashlib.sha256(changed).hexdigest(),
        gameplay_ipc=None,standard_suite=False,production_changed=False),indent=2))
