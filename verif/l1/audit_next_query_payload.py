#!/usr/bin/env python3
"""Independently re-read the next-query candidate's complete cold-run evidence."""
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import sys
from prepare_next_query_payload import transform

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import compare
import tracefmt
import check_faultlog


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    ap.add_argument('--parent', type=Path, required=True)
    args = ap.parse_args()
    root, parent = args.root.resolve(strict=True), args.parent.resolve(strict=True)
    core = root/'core-r3'
    assert __debug__ and root.is_relative_to(Path('/home/yukidama/external/tmp').resolve())
    built, started = load(core/'build-closed.json'), load(core/'build-started.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    models = dict(control=parent/'obj/tb_ventium', candidate=core/'obj/tb_ventium')
    assert sha(models['control']) == '8c8898416ab8af4e6e53f9c4d94e3d9c2bbd1020edce3abdb300272dfc8104d6'
    assert sha(models['candidate']) == built['binary_sha256']
    assert started['changes'] == ['rtl/core/core_mem_chain.svh']
    pins = started['pins'].copy()
    expected = transform((parent/'candidate/rtl/core/core_mem_chain.svh').read_text())
    assert (core/'candidate/rtl/core/core_mem_chain.svh').read_text() == expected
    observed = sorted(str(p.relative_to(core/'candidate')) for p in (core/'candidate').rglob('*')
        if p.is_file() and sha(p) != sha(parent/'candidate'/p.relative_to(core/'candidate')))
    assert observed == ['rtl/core/core_mem_chain.svh']
    for leaf in ('leaf-r1','seam-r1'):
        receipt = load(root/leaf/'closed.json')
        assert receipt['passed'] and receipt['pins_unchanged']
        pins.update(load(root/leaf/'pins.json'))
        pins[str(root/leaf/'closed.json')] = sha(root/leaf/'closed.json')
    native = module('native', REPO/'verif/sys/run-native-system.py')
    fp_driver = Path('/home/yukidama/external/tmp/ventium-fp-exec-cut.MNkzxfBO/system/run_same_profile_fp.py').resolve()
    fp = module('fp_grade', fp_driver)
    pins[str(fp_driver)] = sha(fp_driver)
    units = []

    def owner(unit, stamp, code=0):
        observed = dict(s.split('=',1) for s in subprocess.check_output([
            'systemctl','--user','show',unit,'-pMainPID','-pSubState',
            '-pInvocationID','-pExecMainStatus'],text=True).splitlines())
        assert observed['InvocationID'] == stamp['invocation'] and observed['MainPID'] == '0'
        assert observed['SubState'] == ('exited' if code == 0 else 'failed')
        assert observed['ExecMainStatus'] == str(code)
        units.append(dict(unit=unit,**observed))

    owner('ventium-next-query-core-r3-oct11.service', started)
    counts = dict(cases=0, architectural_records=0, targeted_memory_v=0, agi_accepts=0)
    profiles = []
    for model in models.values():
        stamp = model.parent/'Vventium_top__verFiles.dat'
        command = next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
        defines = set(re.findall(r'\+define\+(\w+)',command))
        assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH_RELOC',
                'VEN_P54_DUAL_LOAD_PAIR','VEN_RAW_V_READ_PRIME'} <= defines
        assert ' --assert ' in command and not {'SYNTHESIS','VTM_NO_DPI','VEN_SYS_FASTPATH_ALL'} & defines
        profiles.append(defines)
        pins.update({str(p):sha(p) for p in (model,stamp)})
    assert profiles[0] == profiles[1]
    for label, cases in (('memory',72),('fp',72),('agi',12)):
        folder = root/(label+'-r1')
        info, done = load(folder/'started.json'), load(folder/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert len(done['measurements']) == cases*4
        pins.update(info['pins'])
        owner('ventium-next-query-'+label+'-oct11.service',info)
        leaves = sorted(folder.glob('*/closed.json'))
        assert len(leaves) == cases
        for closed in leaves:
            leaf = closed.parent
            assert load(closed)['passed']
            assert sha(leaf/'fixture.bin') == load(closed)['image_sha256']
            gold = tracefmt.read_trace(str(leaf/'golden.vtrace'))
            assert gold.sys and gold.x87 == (label != 'memory') and 100 < len(gold.records) < 2000
            assert int(gold.records[-1]['eax'],0)&255 == 0x42
            symbols = {p[2]:int(p[0],16) for s in subprocess.check_output(
                ['nm','-n',leaf/'fixture.elf'],text=True).splitlines()
                if len(p:=s.split())==3 and p[0]!='U'}
            for latency in (0,7):
                records = {}
                agi = {}
                for name, model in models.items():
                    for mode in ('cycle-func','cycle'):
                        stem=name+'-lat'+str(latency)+'-'+mode
                        command=load(leaf/(stem+'.command.json'))
                        assert command.count(str(model)) == 1
                        assert '--'+mode in command and '--l1-axi' in command and '--system' in command
                        assert command[command.index('--max-insn')+1] == '2000'
                        rc=load(leaf/(stem+'.exit.json'))['native_exit']
                        assert rc == 133
                        stdout=(leaf/(stem+'.stdout')).read_text()
                        stderr=(leaf/(stem+'.stderr')).read_text()
                        check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()),{})
                        assert not native.FATAL.search(stdout) and not native.FATAL.search(stderr)
                        trace=tracefmt.read_trace(str(leaf/(stem+'.vtrace')))
                        assert [r['n'] for r in trace.records] == list(range(len(gold.records)))
                        assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]
                        records[(name,mode)] = trace.records
                        if mode == 'cycle-func':
                            grade = native.grade_native if label == 'memory' else fp.grade_fp_native
                            grade(trace,stdout,stderr,rc,133,2000)
                            log=io.StringIO()
                            assert compare.compare_func(gold,trace,False,0xffffffff,False,20,log,sys_both=True)==0,log.getvalue()
                            if name == 'candidate': counts['architectural_records'] += len(trace.records)
                        else:
                            agi[name]=re.findall(r'^\[FETCHDBG:AGIPRIME\] .+$',stdout,re.M)
                    assert records[(name,'cycle')][-1]['cyc'] > 0
                for mode in ('cycle-func','cycle'):
                    assert records[('control',mode)] == records[('candidate',mode)]
                if label == 'memory':
                    counts['targeted_memory_v'] += sum(int(r['pc'],0)==symbols['hot_load'] and
                        r.get('pipe')=='V' and r.get('paired') for r in records[('candidate','cycle')])
                if label == 'agi':
                    assert agi['control'] == agi['candidate'] and agi['candidate']
                    counts['agi_accepts'] += len(agi['candidate'])
            counts['cases'] += 1
        for p in folder.rglob('*'):
            if p.is_file(): pins[str(p)]=sha(p)
    assert counts == dict(cases=156,architectural_records=75192,targeted_memory_v=1500,agi_accepts=350)
    verify=load(core/'verify-closed.json')
    pins.update(load(core/'verify-started.json')['pins'])
    assert verify['pins_unchanged'] and verify['canonical_gate_native_exit']==2
    assert not verify['canonical_gate_passed'] and not verify['masks_or_goldens_or_bands_changed']
    owner('ventium-next-query-verify-oct11.service',load(core/'verify-started.json'),1)
    cycles=sorted((core/'generic-work').glob('*.cycle_rtl.vtrace'))
    assert len(cycles)==20
    for p in cycles:
        q=parent/'generic-work'/p.name
        assert tracefmt.read_trace(str(p)).records == tracefmt.read_trace(str(q)).records
        pins.update({str(f):sha(f) for f in (p,q)})
    for p in (Path(__file__),core/'build-closed.json',core/'build-started.json',
              core/'verify-started.json',core/'verify-closed.json'):
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(audit_complete=True,model_sha256=built['binary_sha256'],pins=pins,
        counts=counts,retained_owners=units,rtl_plus_defines=len(profiles[0]),
        all_20_canonical_cycle_streams_identical=True,canonical_gate_passed=False,
        gameplay_ipc=None,standard_suite=False,physical_board=False)
    with (root/'audit.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','retained_owners')},indent=2))


if __name__=='__main__':
    main()
