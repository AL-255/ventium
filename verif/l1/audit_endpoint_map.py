"""Read-only closure audit of endpoint-map evidence; not gate/hardware acceptance."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

import prepare_endpoint_map as recipe
from run_parallel_tag_cache import sha

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt

MODEL = '164e17003b2ec03cd7b92cc8bbe89b576e5f440becc4204e37368e075c87e8df'
OWNERS = {
    'leaf-oct13-r2': ('f300197aff534351b69875da78347318',0),
    'core-oct13-r1': ('532541fa5b5046a89db6e9e1a5c7216a',0),
    'verify-oct13-r1': ('385fc3c21fa3482eb8fad63c9bf3a38e',1),
    'smsw-oct13-r1': ('79ec3430df534756aa89623511d33933',0),
    'privilege-oct13-r1': ('f078f79f45564fda8226388636ffc365',0),
    'fault-oct13-r2': ('fb1526240c3540f49e71753e7ed6fef4',1),
    'route-oct13-r1': ('080b25c6b63d43d2aca52285aa92e8ea',0),
    'replay-oct13-r1': ('90e0fb95fb8e4c689e512710b5eb3e0e',0),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args = parser.parse_args(); root=args.root.resolve(strict=True); out=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and out.is_relative_to(root) and not out.exists()
    pins={}; owners={}
    def pin(path):
        path=Path(path); value=sha(path)
        assert str(path) not in pins or pins[str(path)]==value
        pins[str(path)]=value
        return path
    def load(path):
        return json.loads(pin(path).read_text())
    def check_pins(source):
        for p,h in source.items():
            assert sha(pin(p))==h
    for short,(invocation,code) in OWNERS.items():
        unit='ventium-endpoint-map-'+short+'.service'
        props=dict(line.split('=',1) for line in subprocess.check_output([
            'systemctl','--user','show',unit,'-p','InvocationID','-p','MainPID',
            '-p','ExecMainStatus','-p','Result','-p','ActiveState','-p','SubState'],text=True).splitlines())
        assert props['InvocationID']==invocation and props['MainPID']=='0'
        assert int(props['ExecMainStatus'])==code
        assert props['SubState']==('exited' if code==0 else 'failed')
        assert props['Result']==('success' if code==0 else 'exit-code')
        owners[unit]=props
    core=root/'endpoint-map-core-r1'; parent=root/'smsw-prime-reg-core-r1'
    start=load(core/'build-started.json'); built=load(core/'build-closed.json')
    assert built['passed'] and built['native_exit']==0 and built['pins_unchanged']
    assert sha(pin(core/'obj/tb_ventium'))==built['binary_sha256']==MODEL
    assert start['changes']==[recipe.FILE] and len(set(start['definitions']))==152
    check_pins(start['pins'])
    before=parent/'candidate'; after=core/'candidate'
    paths=sorted(str(p.relative_to(after)) for p in after.rglob('*') if p.is_file())
    assert len(paths)==195 and paths==sorted(str(p.relative_to(before)) for p in before.rglob('*') if p.is_file())
    assert [p for p in paths if sha(pin(before/p))!=sha(pin(after/p))]==[recipe.FILE]
    assert recipe.transform((before/recipe.FILE).read_text())==(after/recipe.FILE).read_text()
    leaf=load(root/'endpoint-map-leaf-r1/closed.json')
    assert leaf['passed'] and leaf['pins_unchanged']
    check_pins(leaf['pins'])
    assert [r['native_exit'] for r in leaf['rows']]==[0,1,1,1]
    for row in leaf['rows']: check_pins(row['artifacts'])
    route=load(root/'endpoint-map-route-r1/closed.json')
    assert route['passed'] and route['pins_unchanged']
    check_pins(route['pins'])
    for row in route['rows']:
        assert row['build_exit']==row['native_exit']==0
        check_pins(row['artifacts'])
    functional=[]
    for label,old_label,count in (('smsw','diff',88),('privilege','privilege',60),('fault','fault',45)):
        new=root/('endpoint-map-'+label+'-r1'); old=root/('smsw-prime-reg-'+old_label+'-r1')
        closed=load(new/'closed.json'); started=load(new/'started.json')
        assert closed['pins_unchanged'] and not closed['errors'] and len(closed['rows'])==count
        assert closed['passed']==(label!='fault')
        check_pins(started['pins'])
        if 'artifacts' in closed: check_pins(closed['artifacts'])
        if label=='fault':
            assert sum(r['compare_exit']==0 for r in closed['rows'])==25
            assert sum(r['compare_exit']==1 for r in closed['rows'])==20
            assert all(r['rtl_native_exit']==133 for r in closed['rows'])
        for row in closed['rows']:
            if 'artifacts' in row: check_pins(row['artifacts'])
            relative=(row['name']+'.vtrace') if label=='smsw' else (row['name']+'/candidate.vtrace')
            a=tracefmt.read_trace(str(pin(old/relative))); b=tracefmt.read_trace(str(pin(new/relative)))
            assert a.mode==b.mode=='func' and a.sys and b.sys
            assert a.records==b.records and len(b.records)==row['records'], (label,row['name'])
            if label!='smsw':
                assert sha(pin(old/row['name']/'probe.bin'))==sha(pin(new/row['name']/'probe.bin'))
            functional.append(dict(group=label,case=row['name'],records=len(b.records)))
    verified=load(core/'verify-closed.json'); verification=load(core/'verify-started.json')
    assert verified['canonical_gate_native_exit']==2 and not verified['canonical_gate_passed']
    assert verified['pins_unchanged'] and not verified['masks_or_goldens_or_bands_changed']
    check_pins(verification['pins'])
    assert len(verified['deltas'])==20 and all(r['same_records'] for r in verified['deltas'])
    assert 'func totals: 7 PASS / 101 FAIL / 108 total' in pin(core/'generic.log').read_text()
    for row in verified['deltas']:
        traces=[tracefmt.read_trace(str(pin(p/'generic-work'/row['name']))) for p in (parent,core)]
        assert traces[0].records==traces[1].records
    replay_root=root/'endpoint-map-replay-r1'
    replay=load(replay_root/'closed.json'); replay_start=load(replay_root/'started.json')
    assert replay['same_input_regression_passed'] and replay['pins_unchanged'] and not replay['errors']
    assert len(replay['rows'])==108 and replay['records']==80800
    check_pins(replay_start['pins'])
    for row in replay['rows']:
        paths=[replay_root/row['case']/(n+'.vtrace') for n in ('control','candidate')]
        paths.append(core/'generic-work'/(row['case']+'.func_rtl.vtrace'))
        traces=[tracefmt.read_trace(str(pin(p))) for p in paths]
        assert traces[0].records==traces[1].records==traces[2].records
    for p in (Path(__file__),Path(recipe.__file__),REPO/'verif/diff/tracefmt.py'): pin(p)
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(audit_passed=True,model=MODEL,changed_files=[recipe.FILE],owners=owners,pins=pins,
        exact_parent_cases=len(functional),exact_parent_records=sum(r['records'] for r in functional),
        qemu_differential_cases=173,intel_spec_only_cases=20,complete_fault_differential_gate_passed=False,
        canonical_gate_passed=False,canonical_native_exit=2,canonical_same_input_cases=108,
        canonical_same_input_records=80800,canonical_cycle_traces=20,
        standard_suite=False,hardware_acceptance=False,fmax_mhz=None,gameplay_ipc=None)
    with out.open('x') as stream: json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','owners')},indent=2))


if __name__=='__main__': main()
