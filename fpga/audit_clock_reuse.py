"""Check Vivado's canonical reuse table, separately from primitive properties."""
import argparse
import json
from pathlib import Path
import re


def validate(text):
    tables=[]
    for line in text.splitlines():
        if line.startswith('|') and line.rstrip().endswith('|'):
            tables.append([part.strip() for part in line.strip().strip('|').split('|')])
    headers=[row for row in tables if row[0]=='Type' and 'Total' in row]
    initial=['Type','Matched % (of Total)','Current Reuse % (of Total)',
             'Fixed % (of Total)','Total']
    placed=['Type','Matched % (of Initial Total)','Initial Reuse % (of Initial Total)',
            'Current Reuse % (of Total)','Fixed % (of Total)','Total']
    if len(headers)!=1 or headers[0] not in (initial,placed):
        raise ValueError('missing/ambiguous/unsupported canonical reuse header')
    header=headers[0]
    result={}
    for kind, minimum in (('Cells',200000),('Nets',150000)):
        rows=[row for row in tables if row[0]==kind]
        if len(rows)!=1 or len(rows[0])!=len(header):
            raise ValueError('missing/ambiguous canonical '+kind+' reuse row')
        columns=dict(zip(header,rows[0]))
        if any(not re.fullmatch(r'[0-9]+(?:\.[0-9]+)?',value) for value in rows[0][1:]):
            raise ValueError('invalid canonical numeric value')
        matched=float(rows[0][1])
        reused=float(columns['Current Reuse % (of Total)'])
        fixed=float(columns['Fixed % (of Total)'])
        total=int(columns['Total'])
        if header==placed and not 99.5<=float(columns['Initial Reuse % (of Initial Total)'])<=100:
            raise ValueError('insufficient canonical initial '+kind+' reuse')
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
