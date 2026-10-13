"""Independently require fresh post-store REP decode bytes in the closed AXI test.

The stores modify unused executable padding: architectural equality alone
cannot prove refetch. Check both decode episodes and bypass-only poison too.
"""
import argparse
import json
import os
from pathlib import Path
import re

from run_l1_write_kind_system import sha,save


def witness(stdout,cached):
    decodes=re.findall(r'\[FETCHDBG:DECODE\].*eip=00020008\b.*bytes=([0-9a-fA-F]+)',stdout)
    assert len(decodes)==2, ('REP decode count',decodes)
    a,b=map(bytes.fromhex,decodes)
    assert a[:4]==b[:4]==bytes.fromhex('f3abeb0a')
    assert a[4:12]==bytes(8) and b[4:12]==bytes.fromhex('d3c45b6a00000000'), 'stale REP bytes'
    hits=re.findall(r'^\[REPICBP\] HIT .*q_pc=00020008\b.*ic_snp1_hit=([01])\b.*ic_snp2_hit=([01])\b',stdout,re.M)
    if not cached:
        assert hits and all(a==b=='0' for a,b in hits),'no bypass-only invalidation witness'
    assert not re.search(r'^\[REPCONT\] (?:ARM|BOUNDARY) .*q_pc=00020008\b',stdout,re.M)
    return dict(fresh_rep_decodes=2,bypass_only_hits=len(hits))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();root=args.run.resolve(strict=True);out=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and out.is_relative_to(scratch) and not out.exists()
    before=json.loads((root/'started.json').read_text());done=json.loads((root/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and not done['errors'] and len(done['rows'])==24
    pins=dict(before['pins'])
    for p in (Path(__file__),root/'started.json',root/'closed.json'):pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    rows=[];negative=0
    for row in done['rows']:
        folder=root/('cached' if row['cached'] else 'bypass')
        stem=f"{row['model']}-l{row['latency']}-{row['mode']}"
        trace=folder/(stem+'.vtrace');assert sha(trace)==row['trace_sha256']
        text=(folder/(stem+'.stdout')).read_text();proof=witness(text,row['cached'])
        cmd=json.loads((folder/(stem+'.command.json')).read_text())
        assert '--l1-axi' in cmd['command'] and '--'+row['mode'] in cmd['command']
        assert cmd['latency']==row['latency']
        assert json.loads((folder/(stem+'.exit.json')).read_text())['native_exit']==133
        assert row['axi_drained'] and row['axi_reads']>0
        assert row['probe']['agi']>0 and row['probe']['ref']>0
        if row['mode']=='cycle':assert row['paired_v']>0
        for suffix in ('.vtrace','.stdout','.stderr','.command.json','.exit.json'):
            p=folder/(stem+suffix);pins[str(p)]=sha(p)
        # The checker must reject unchanged post-store bytes in the actual log.
        bad=text.replace('bytes=f3abeb0ad3c45b6a00000000','bytes=f3abeb0a0000000000000000')
        assert bad!=text
        try:witness(bad,row['cached'])
        except AssertionError:negative+=1
        else:raise AssertionError('accepted stale REP decode')
        rows.append(dict(cached=row['cached'],latency=row['latency'],model=row['model'],mode=row['mode'],**proof))
    assert len(rows)==negative==24 and all(sha(p)==h for p,h in pins.items())
    save(out,dict(passed=True,rows=rows,pins=pins,pins_unchanged=True,stale_decode_negative_controls=negative,
                  gameplay_ipc=None,standard_suite=False,hardware_acceptance=False))
    print('PRIME-SMC-AUDIT-OK runs=24 fresh-decodes=48 stale-negative-controls=24')


if __name__=='__main__':main()
