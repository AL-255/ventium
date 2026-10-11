#!/usr/bin/env python3
"""Re-read complete native evidence for the idle-state SRT quotient initialization."""
import argparse
import io
import json
from pathlib import Path
import re
import subprocess
import sys
sys.path[:0] = ['/home/yukidama/github/ventium/verif/l1', '/home/yukidama/github/ventium/verif/srt']
from audit_next_query_payload import sha, load, module, REPO, compare, tracefmt, check_faultlog
from prepare_qacc_idle_payload import transform


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for flag in ('root', 'parent'):
        ap.add_argument('--'+flag, type=Path, required=True)
    args = ap.parse_args()
    root, parent = args.root.resolve(strict=True), args.parent.resolve(strict=True)
    core = root/'core-r1'
    assert __debug__ and root.is_relative_to(Path('/home/yukidama/external/tmp').resolve())
    built, started = load(core/'build-closed.json'), load(core/'build-started.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    models = dict(control=parent/'obj/tb_ventium', candidate=core/'obj/tb_ventium')
    assert sha(models['control']) == started['parent_model'] == '95f6dbb8699839d8e4af879b07c37d3143311acbe910178e8ee009ac36d984ca'
    assert sha(models['candidate']) == built['binary_sha256'] == '33fb210acc14e9f880f493767cfb9fbf0cd4304038a925a521856384680631c7'
    delta = 'rtl/fpu/fpu_srt_div.sv'
    observed = sorted(str(p.relative_to(core/'candidate')) for p in (core/'candidate').rglob('*')
        if p.is_file() and sha(p) != sha(parent/'candidate'/p.relative_to(core/'candidate')))
    assert observed == started['changes'] == [delta]
    assert (core/'candidate'/delta).read_text() == transform((parent/'candidate'/delta).read_text())
    pins, owners = started['pins'].copy(), []

    def owner(unit, invocation, code=0):
        actual = dict(s.split('=', 1) for s in subprocess.check_output(['systemctl', '--user', 'show', unit,
            '-pSubState', '-pMainPID', '-pExecMainStatus', '-pInvocationID'], text=True).splitlines())
        assert actual == dict(SubState='exited' if code == 0 else 'failed', MainPID='0',
                              ExecMainStatus=str(code), InvocationID=invocation), (unit, actual)
        owners.append(dict(unit=unit, **actual))

    owner('ventium-srt-qacc-idle-core-oct11.service', '1356d8a7925444c18b311802d6a9aeed')
    config = subprocess.check_output(['systemctl','--user','cat',
        'ventium-srt-qacc-idle-core-oct11.service'],text=True)
    assert 'VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32' in config
    assert 'build_qacc_idle_core.py' in config and root.name in config
    header=Path(built['private_header'])
    assert header.resolve()==(core/'obj/Vventium_top___024root.h').resolve()
    host=Path(started['host'])
    dependency=(core/'obj'/(host.stem+'.d')).read_text().replace('\\\n',' ')
    dependencies=[Path(s) for s in dependency.split() if Path(s).name==header.name]
    assert len(dependencies)==1
    compiled_header=dependencies[0] if dependencies[0].is_absolute() else core/'obj'/dependencies[0]
    assert compiled_header.resolve()==header.resolve()
    assert (core/'obj'/(host.stem+'.o')).is_file()
    leaf = load(root/'miter-r1/closed.json')
    assert leaf['passed'] and leaf['pins_unchanged']
    assert [(r['label'],r['native_exit']) for r in leaf['runs']]==[
        ('candidate',0),('negative-busy-clear',1)]
    pins.update(leaf['pins'])
    owner('ventium-srt-qacc-idle-miter-oct11.service','15fde2ff68bd4b5c9993a04202ce433f')
    for row in leaf['runs']:
        path=root/'miter-r1'/row['label']/'run.log'
        assert sha(path)==row['log_sha256']
        pins[str(path)]=sha(path)
    assert 'SRT-QACC-MITER-OK samples=5024 ' in (root/'miter-r1/candidate/run.log').read_text()
    assert 'SRT_QACC_LIVE_MISMATCH' in (root/'miter-r1/negative-busy-clear/run.log').read_text()
    proof=load(root/'liveness-proof.json')
    assert proof['passed'] and not proof['whole_rtl_formal_equivalence']
    assert [(r['mutant'],r['result']) for r in proof['runs']]==[
        (None,'unsat'),('missing-rem','sat'),('busy-clear','sat')]
    pins[str(root/'liveness-proof.json')]=sha(root/'liveness-proof.json')
    profiles = []
    for model in models.values():
        stamp = model.parent/'Vventium_top__verFiles.dat'
        command = next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
        profiles.append(set(re.findall(r'\+define\+(\w+)', command)))
        assert ' --assert ' in command and not {'SYNTHESIS', 'VTM_NO_DPI', 'VEN_SYS_FASTPATH_ALL'} & profiles[-1]
        pins.update({str(p):sha(p) for p in (model, stamp)})
    assert profiles[0] == profiles[1] and len(profiles[0]) == 150
    assert {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTSTORE_FLAT', 'VEN_P54_LOAD_STORE_PAIR', 'VEN_L1_AXI'} <= profiles[0]
    native = module('native', REPO/'verif/sys/run-native-system.py')
    helper = Path('/home/yukidama/external/tmp/ventium-fp-exec-cut.MNkzxfBO/system/run_same_profile_fp.py').resolve()
    fp = module('fp_grade', helper)
    pins[str(helper)] = sha(helper)
    counts = dict(cases=0, architectural_records=0, targeted_memory_v=0, agi_accepts=0)
    paired_shapes = {}
    for label, cases in (('memory',72), ('fp',72), ('agi',12)):
        folder = root/(label+'-r1')
        info, done = load(folder/'started.json'), load(folder/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert len(done['measurements']) == cases*4
        pins.update(info['pins'])
        owner('ventium-qacc-idle-'+label+'-oct11.service', info['invocation'])
        leaves = sorted(folder.glob('*/closed.json'))
        assert len(leaves) == cases
        for receipt in leaves:
            path, closed = receipt.parent, load(receipt)
            assert closed['passed'] and sha(path/'fixture.bin') == closed['image_sha256']
            gold = tracefmt.read_trace(str(path/'golden.vtrace'))
            symbols = {p[2]:int(p[0],16) for s in subprocess.check_output(['nm','-n',path/'fixture.elf'],text=True).splitlines()
                       if len(p:=s.split()) == 3 and p[0] != 'U'}
            assert gold.sys and gold.x87 == (label in ('fp', 'agi'))
            assert 100 < len(gold.records) < 2000 and int(gold.records[-1]['eax'],0)&255 == 0x42
            for latency in (0,7):
                records, agi = {}, {}
                for name, model in models.items():
                    for mode in ('cycle-func', 'cycle'):
                        stem = '%s-lat%d-%s' % (name, latency, mode)
                        command = load(path/(stem+'.command.json'))
                        assert str(model) in command and '--'+mode in command and '--l1-axi' in command
                        assert '--system' in command and '--cosim' in command
                        assert command[command.index('--max-insn')+1] == '2000'
                        rc = load(path/(stem+'.exit.json'))['native_exit']
                        assert rc == 133
                        stdout, stderr = (path/(stem+'.stdout')).read_text(), (path/(stem+'.stderr')).read_text()
                        check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()), {})
                        assert not native.FATAL.search(stdout+stderr)
                        tr = tracefmt.read_trace(str(path/(stem+'.vtrace')))
                        assert [r['n'] for r in tr.records] == list(range(len(gold.records)))
                        assert [r['pc'] for r in tr.records] == [r['pc'] for r in gold.records]
                        records[name,mode] = tr.records
                        if mode == 'cycle-func':
                            (fp.grade_fp_native if label in ('fp','agi') else native.grade_native)(tr,stdout,stderr,rc,133,2000)
                            log = io.StringIO()
                            assert compare.compare_func(gold,tr,False,0xffffffff,False,20,log,sys_both=True) == 0, log.getvalue()
                            if name == 'candidate': counts['architectural_records'] += len(tr.records)
                        else: agi[name] = re.findall(r'^\[FETCHDBG:AGIPRIME\] .+$',stdout,re.M)
                for mode in ('cycle-func','cycle'):
                    assert records['control',mode] == records['candidate',mode]
                if label in ('memory','system'):
                    nv = sum(int(r['pc'],0)==symbols['hot_load'] and r.get('pipe')=='V' and r.get('paired')
                             for r in records['candidate','cycle'])
                    counts['targeted_memory_v' if label=='memory' else 'targeted_store_v'] += nv
                    if label == 'system':
                        shape = closed['measurements'][0]['case'][0]
                        paired_shapes[shape] = paired_shapes.get(shape,0)+nv
                        if shape in ('same-bank','alias','split'): assert nv == 0
                if label == 'agi':
                    assert agi['control'] == agi['candidate'] and agi['candidate']
                    counts['agi_accepts'] += len(agi['candidate'])
            counts['cases'] += 1
        pins.update({str(p):sha(p) for p in folder.rglob('*') if p.is_file()})
    assert counts == dict(cases=156, architectural_records=75192, targeted_memory_v=1500, agi_accepts=350)
    assert paired_shapes == {}
    faults=load(root/'faults-r1/closed.json')
    assert faults['passed'] and faults['pins_unchanged'] and not faults['errors']
    assert len(faults['measurements'])==32
    owner('ventium-qacc-idle-faults-oct11.service','7f262d1896854b308fa51dd787612415')
    pins.update(load(root/'faults-r1/started.json')['pins'])
    pins.update({str(root/'faults-r1'/p):h for p,h in faults['artifacts'].items()})
    pins[str(root/'faults-r1/closed.json')]=sha(root/'faults-r1/closed.json')
    verify, vst = load(core/'verify-closed.json'), load(core/'verify-started.json')
    assert verify['pins_unchanged'] and verify['canonical_gate_native_exit'] == 2 and not verify['canonical_gate_passed']
    assert not verify['masks_or_goldens_or_bands_changed']
    owner('ventium-qacc-idle-verify-oct11.service', vst['invocation'], 1)
    pins.update(vst['pins'])
    cycles = sorted((core/'generic-work').glob('*.cycle_rtl.vtrace'))
    assert len(cycles) == 20
    for p in cycles:
        q = parent/'generic-work'/p.name
        assert tracefmt.read_trace(str(p)).records == tracefmt.read_trace(str(q)).records
        pins.update({str(f):sha(f) for f in (p,q)})
    for p in (Path(__file__), REPO/'verif/l1/audit_next_query_payload.py',
              core/'build-closed.json', core/'build-started.json', core/'verify-closed.json',
              core/'verify-started.json', root/'miter-r1/closed.json'):
        pins[str(p)] = sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    result = dict(audit_complete=True, model_sha256=built['binary_sha256'], pins=pins, retained_owners=owners,
        counts=counts, paired_shapes=paired_shapes, all_20_canonical_cycle_streams_identical=True,
        canonical_gate_passed=False, gameplay_ipc=None, standard_suite=False, physical_board=False,
        focused_fault_cases=16, full_fault_sweep=False, reset_sweep=False, timing_mhz=None)
    with (root/'audit.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','retained_owners')},indent=2))


if __name__ == '__main__': main()
