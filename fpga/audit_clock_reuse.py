"""Check Vivado's canonical reuse table, separately from primitive properties."""
import argparse
import json
from pathlib import Path
import re


def validate(text):
    result={}
    for kind, minimum in (('Cells',200000),('Nets',150000)):
        rows=re.findall(r'^\|\s*'+kind+r'\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|\s*(\d+)\s*\|',text,re.M)
        if len(rows)!=1: raise ValueError('missing/ambiguous canonical '+kind+' reuse row')
        matched,reused,fixed,total=rows[0]
        matched,reused,fixed,total=float(matched),float(reused),float(fixed),int(total)
        if not (99.5<=matched<=100 and 99.5<=reused<=100 and 0<=fixed<=100 and total>=minimum):
            raise ValueError('insufficient canonical '+kind+' reuse')
        result[kind]=dict(matched_pct=matched,reused_pct=reused,fixed_pct=fixed,total=total)
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('report',type=Path)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    result=validate(args.report.read_text())
    with args.out.open('x') as stream: json.dump(result,stream,indent=2)
    print('CLOCK-CANONICAL-REUSE-OK',json.dumps(result))
