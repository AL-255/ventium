"""Verify closed, source-matched cache synthesis without claiming CPU timing."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess

from run_way_banked_tag_probe import sha


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',required=True,type=Path)
    args=ap.parse_args()
    root=args.root.resolve(strict=True)
    data=Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve(strict=True)
    assert __debug__ and root==data/'way-banked-tag-probe-r1'
    load=lambda p: json.loads(p.read_text())
    started,closed=load(root/'started.json'),load(root/'closed.json')
    assert closed['passed'] and closed['native_exit']==0 and closed['pins_unchanged']
    assert closed['controller_failure'] is None and closed['resource_stop'] is None
    assert closed['cpu_fmax'] is None and not closed['routed'] and not closed['hardware_acceptance']
    owner=dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show','ventium-way-tags-probe-oct14-r1.service',
        '-p','InvocationID','-p','MainPID','-p','SubState','-p','ExecMainStatus'],text=True).splitlines())
    assert owner==dict(InvocationID=started['controller_invocation'],MainPID='0',SubState='exited',ExecMainStatus='0')
    samples=[json.loads(line) for line in (root/'watch.jsonl').read_text().splitlines()]
    assert samples and all(not r['reason'] and not any(r['events'][k]
        for k in ('oom','oom_kill','oom_group_kill')) for r in samples)
    assert all(set(task['affinity'])<={16,17,18,19} for row in samples for task in row['tasks'])
    native=(root/'native.log').read_text()
    assert not re.search(r'^ERROR:',native,re.M) and '\nWAY_BANKED_TAG_SYNTHESIS_OK\n' in native
    receipt=(root/'reports/receipt.tcllist').read_text()
    assert receipt.splitlines()[-1]=='COMPLETE PROFILES 2 CPU_FMAX_QUALIFIED 0 HARDWARE_ACCEPTANCE 0'
    evidence={}
    for label in ('parent','candidate'):
        lines=(root/f'reports/{label}-primitives.tsv').read_text().splitlines()
        assert lines.pop(0)=='cell\tref_name'
        tags=Counter()
        names=set()
        for line in lines:
            name,ref=line.split('\t')
            assert name not in names
            names.add(name)
            if 'dc_tag' in name:
                tags[ref]+=1
        ff=sum(n for ref,n in tags.items() if ref.startswith('FD'))
        ram=sum(n for ref,n in tags.items() if ref.startswith('RAM'))
        assert f'TAG_FF {ff} TAG_RAM {ram}' in receipt
        if label=='parent':
            assert ff==5120 and ram==0
        else:
            assert ff==0 and ram>0
        util=(root/f'reports/{label}-util.rpt').read_text()
        matches=[line for line in util.splitlines() if re.match(r'^\| ven_l1d\s+\|',line)]
        assert len(matches)==1
        fields=[part.strip() for part in matches[0].split('|')][1:-1]
        assert fields[:2]==['ven_l1d','(top)'] and len(fields)==11
        counts=dict(zip(('luts','logic_luts','lutram','srl','ff','ramb36','ramb18','uram','dsp'),map(int,fields[2:])))
        evidence[label]=dict(tag_types=dict(tags),tag_ff=ff,tag_ram=ram,utilization=counts)
    delta={k:evidence['candidate']['utilization'][k]-v for k,v in evidence['parent']['utilization'].items()}
    pins=dict(started['pins'])
    for p in (Path(__file__).resolve(),root/'started.json',root/'closed.json',root/'watch.jsonl',root/'native.log',
              *sorted((root/'reports').iterdir())):
        assert p.is_file() and not p.is_symlink()
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(passed=True,pins=pins,checked_pins=len(pins),owner=owner,
        scope_invocation=closed['owner']['InvocationID'],seconds=closed['seconds'],
        memory_peak=closed['memory_peak'],swap_peak=closed['swap_peak'],no_oom=True,
        profiles=evidence,delta=delta,whole_core=False,cpu_fmax=None,hardware_acceptance=False,routed=False)
    with (root/'audit.json').open('x') as f:
        json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}))


if __name__=='__main__':
    main()
