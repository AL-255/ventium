#!/usr/bin/env python3
"""AGI load fault/retry: unchanged full QEMU oracle, older-FP metadata checks."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('reference_events',HERE/'run-ref-prime-fp-events.py')
reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(reference)


def transform(text):
    text=reference.transform(text,True,True)
    text=reference.once(text,"else 'VEN_REF_OPERAND_PRIME'","else 'VEN_RAW_AGI_PRIME'")
    text=reference.once(text,"prepare-ref-prime-int-fault.py'","prepare-agi-prime-fault.py'")
    anchor="    save(args.out/'inputs.json', pins)"
    text=reference.once(text,anchor,"    for name in ('prepare-ref-prime-int-fault.py', 'run-agi-prime-fault.py'):\n"
              "        p=REPO/'verif/fe_pipe'/name; pins[str(p)]=sha(p)\n"+anchor)
    return text


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('control','candidate','out'):ap.add_argument('--'+name,type=Path,required=True)
    args=ap.parse_args()
    source=HERE/'run-fp-mem64-queue.py'
    original=source.read_bytes();digest=hashlib.sha256(original).hexdigest()
    text=transform(original.decode())
    with args.out.with_name(args.out.name+'-driver.json').open('x') as f:
        json.dump(dict(source=str(source),sha256=digest,
            transformed_sha256=hashlib.sha256(text.encode()).hexdigest(),
            feature='VEN_RAW_AGI_PRIME',standard_suite=False,gameplay_ipc=None),f,indent=2)
    sys.argv=[str(source),'--control',str(args.control),'--candidate',str(args.candidate),
              '--out',str(args.out),'--feature','ref-operand-prime','--fault']
    try:exec(compile(text,str(source),'exec'),{'__file__':str(source),'__name__':'__main__'})
    finally:assert hashlib.sha256(source.read_bytes()).hexdigest()==digest


if __name__=='__main__':main()
