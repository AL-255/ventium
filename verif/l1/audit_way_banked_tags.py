"""Independently check exact sources, closed children and full-cache A/B evidence."""
import argparse
import json
from pathlib import Path
import re
import subprocess

import prepare_way_banked_tags as recipe
from run_parallel_tag_cache import control_source, sha


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', required=True, type=Path)
    args=ap.parse_args()
    root=args.root.resolve(strict=True)
    data=Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve(strict=True)
    assert __debug__ and root==data/'way-banked-tag-cache-r1'
    prior=data/'parallel-next-tag-cache-r1'
    load=lambda p: json.loads(p.read_text())
    closed, started=load(root/'closed.json'),load(root/'started.json')
    assert closed['passed'] and closed['pins_unchanged'] and closed['error'] is None
    assert not any(int(closed['memory_events'][k]) for k in ('oom','oom_kill','oom_group_kill'))
    unit='ventium-way-tags-cache-oct14-r1.service'
    owner=dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',unit,'-p','InvocationID','-p','SubState',
        '-p','MainPID','-p','ExecMainStatus'],text=True).splitlines())
    assert owner==dict(InvocationID='459ac1afb8a3478eae4b34f43927163c',
                      SubState='exited',MainPID='0',ExecMainStatus='0')
    assert started['invocation']=='8272ba177664446cbe375f592bae1df6'
    journal=subprocess.check_output(['journalctl','--user',
        '_SYSTEMD_INVOCATION_ID='+started['invocation'],'-o','cat','--no-pager'],text=True)
    recorded=[json.loads(line) for line in journal.splitlines() if line.startswith('{"passed":')]
    assert len(recorded)==1 and recorded[0]=={k:v for k,v in closed.items() if k not in ('pins','rows')}
    original=(prior/'positive/ven_l1d.sv').read_text()
    changed=recipe.transform(original)
    assert (root/'control_l1d.sv').read_text()==control_source(original)
    assert (root/'tb_l1d_mem_chain.sv').read_text()==recipe.miter_fixture((prior/'tb_l1d_mem_chain.sv').read_text())
    variants=dict(positive=changed,
        **{'wrong-write-way':changed.replace('if (fway) dc_tag_way1[fset]', 'if (!fway) dc_tag_way1[fset]'),
           'wrong-snoop-way':changed.replace('dc_tag_way1[snp_set]', 'dc_tag_way0[snp_set]')})
    assert [r['name'] for r in closed['rows']]==list(variants)
    pins=dict(started['pins'])
    assert pins==closed['pins']
    prior_command=load(prior/'closed.json')['rows'][0]['command']
    for row in closed['rows']:
        folder=root/row['name']
        assert (folder/'ven_l1d.sv').read_text()==variants[row['name']]
        expected=[s.replace(str(prior),str(root)).replace(str(root/'positive'),str(folder)) for s in prior_command]
        assert row['command']==expected and row['build_exit']==0
        assert len([s for s in expected if s.startswith('+define+')])==152
        assert not re.search(r'%Error', (folder/'build.log').read_text())
        native=load(folder/'native.json')
        assert native['exit_code']==row['native_exit'] and native['reaped']
        sample=native['observed']
        assert sample['exe']==str(folder/'obj/test') and sample['affinity']==[12]
        assert sample['argv']==native['argv']==[str(folder/'obj/test'),'+OBS='+str(folder/'cycles.txt')]
        assert sample['cgroup'].strip().endswith('/ventium-ipc-parallel32.scope')
        log=(folder/'run.log').read_text()
        if row['name']=='positive':
            assert row['native_exit']==0 and not re.search(r'FAIL|%Error|%Fatal|MISMATCH',log)
            assert re.findall(r'^PARALLEL-CACHE-MITER checks=(\d+) next=(\d+)$',log,re.M)==[('747037','463')]
            assert re.findall(r'^PARALLEL-NEXT-CACHE-COVERAGE hit=(\d+) owner=(\d+) crossing=(\d+)$',log,re.M)==[('361977','463','6984')]
            assert 'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4' in log
            assert sha(folder/'cycles.txt')==sha(prior/'positive/cycles.txt')
        else:
            assert row['native_exit']!=0 and 'PARALLEL-CACHE-MISMATCH' in log
        pins.update(row['artifacts'])
    for p in (Path(__file__).resolve(),root/'started.json',root/'closed.json'):
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(passed=True,pins=pins,checked_pins=len(pins),owner=owner,
        inner_invocation=started['invocation'],whole_cache=True,samples=747037,
        rejected_mutations=2,actual_native_cpu=12,seconds=closed['seconds'],
        memory_peak=closed['memory_peak'],no_oom=True,source_sha256=sha(root/'positive/ven_l1d.sv'),
        whole_core=False,gameplay_ipc=None,standard_suite=False,hardware_acceptance=False,timing_mhz=None)
    with (root/'audit.json').open('x') as f:
        json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}))


if __name__=='__main__':
    main()
