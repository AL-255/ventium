#!/usr/bin/env python3
"""Complete QEMU event oracle for integer AGI warmup (no debugger STEP)."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

HERE=Path(__file__).resolve().parent


def once(text,old,new):
    if text.count(old)!=1:raise ValueError('missing/ambiguous event driver anchor: '+old)
    return text.replace(old,new)


def transform(text):
    changes={
        "else 'VEN_FP_SCALAR_LOAD_CMD'":"else 'VEN_RAW_AGI_PRIME'",
        "prepare-fp-scalar-load-events.py'":"prepare-agi-prime-events.py'",
        "    save(args.out / 'inputs.json', pins)":
        "    pins[str(HERE/'run-agi-prime-events.py')]=sha(HERE/'run-agi-prime-events.py')\n"
        "    save(args.out / 'inputs.json', pins)",
        "read_text().splitlines()), {(7, 0): 2})":"read_text().splitlines()), {})",
        "        assert len(hits) == 10  # Eight visits, plus the two fault-delivery records.":
        "        assert len(hits) == 8  # Integer loads must NOT raise #NM for TS or EM.",
        "==symbols['nm_handler']])==2":"==symbols['nm_handler']])==0",
        "cases = [(k, 0, 0, 17, 0x37f) for k in range(3)]":
        "cases = [(k, cd, 0, 17, 0x37f) for k in range(3) for cd in (0,1)]",
        "r'\\[FPLOADCMD\\] ACCEPT cyc=\\d+ pc=' +\n                                            f'{symbols[\"hot_op\"]:08x}'":
        "r'\\[FETCHDBG:AGIPRIME\\] eip=' +\n                                            f'{symbols[\"hot_load\"]:08x}'",
        "assert all(0 < r[witness] <= 12 for r in result['measurements'] if r['model']=='candidate'), 'TF/RF must not elide the response path'":
        "assert all((0 < r[witness] <= 14 if r['case'][1]==0 else r[witness]==0) for r in result['measurements'] if r['model']=='candidate'), 'TF boundary and cache-disabled negative control'",
    }
    for old,new in changes.items():text=once(text,old,new)
    return text


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('control','candidate','out'):ap.add_argument('--'+name,type=Path,required=True)
    args=ap.parse_args()
    source=HERE/'run-fp-scalar-events.py'
    original=source.read_bytes();digest=hashlib.sha256(original).hexdigest()
    text=transform(original.decode())
    with args.out.with_name(args.out.name+'-driver.json').open('x') as f:
        json.dump(dict(source=str(source),sha256=digest,
            transformed_sha256=hashlib.sha256(text.encode()).hexdigest(),
            feature='VEN_RAW_AGI_PRIME',standard_suite=False,gameplay_ipc=None),f,indent=2)
    sys.argv=[str(source),'--control',str(args.control),'--candidate',str(args.candidate),
              '--out',str(args.out),'--feature','scalar-load-cmd']
    try:exec(compile(text,str(source),'exec'),{'__file__':str(source),'__name__':'__main__'})
    finally:assert hashlib.sha256(source.read_bytes()).hexdigest()==digest


if __name__=='__main__':main()
