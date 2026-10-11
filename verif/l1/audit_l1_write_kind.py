#!/usr/bin/env python3
"""Re-read complete native evidence for the one-file write-direction experiment."""
import argparse
import io
import json
from pathlib import Path
import re
import subprocess
from audit_next_query_payload import sha, load, module, REPO, compare, tracefmt, check_faultlog
from prepare_l1_write_kind_payload import transform


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
    assert sha(models['control']) == started['parent_model'] == 'b5554a977cd1ef4f12ee4a55a92fa514608cc902178aec2060a71fd00537e442'
    assert sha(models['candidate']) == built['binary_sha256'] == '1bfb1bb2f6179ba13384cfdd3f4ded7ac5742108ef21add23e6da1f301286e8c'
    delta = 'rtl/mem/ven_l1d.sv'
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

    unit = 'ventium-l1-write-kind-core-oct11.service'
    owner(unit, '9053e785e6f44b29a8734751a182f976')
    config = subprocess.check_output(['systemctl', '--user', 'cat', unit], text=True)
    assert 'VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32' in config
    assert 'build_l1_write_kind_core.py' in config and str(root.name) in config
    journal = [json.loads(s) for s in subprocess.check_output(['journalctl', '--user',
        '_SYSTEMD_INVOCATION_ID='+started['invocation'], '--no-pager', '-o', 'json'], text=True).splitlines()]
    closures = [r for r in journal if isinstance(r.get('MESSAGE'), str) and r['MESSAGE'].startswith('{"passed":')]
    assert len(closures) == 1 and json.loads(closures[0]['MESSAGE']) == built
    assert closures[0]['_SYSTEMD_USER_UNIT'] == 'ventium-ipc-parallel32.scope'
    assert 'build_l1_write_kind_core.py' in closures[0]['_CMDLINE']
    leaf = load(root/'leaf-r1/closed.json')
    assert leaf['passed'] and leaf['pins_unchanged']
    assert [(r['label'], r['native_exit']) for r in leaf['runs']] == [('build', 0), ('positive', 0), ('negative', 1)]
    pins.update(leaf['pins'])
    owner('ventium-l1-write-kind-leaf-oct11.service', '7d6a33a37c124d92919cffdee2f0fe68')
    for row in leaf['runs']:
        assert sha(root/'leaf-r1'/(row['label']+'.log')) == row['log_sha256']
    assert 'samples=16384 active=4608 inactive_direction_changes=384' in (root/'leaf-r1/positive.log').read_text()
    assert 'WRITE_KIND_CHANGED_ACTIVE_DIRECTION' in (root/'leaf-r1/negative.log').read_text()
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
    counts = dict(cases=0, architectural_records=0, targeted_memory_v=0, agi_accepts=0, targeted_store_v=0)
    paired_shapes = {}
    for label, cases in (('system',72), ('memory',72), ('fp',72), ('agi',12)):
        folder = root/(label+'-r1')
        info, done = load(folder/'started.json'), load(folder/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert len(done['measurements']) == cases*4
        pins.update(info['pins'])
        owner('ventium-l1-write-kind-'+label+'-oct11.service', info['invocation'])
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
    assert counts == dict(cases=228, architectural_records=107304, targeted_memory_v=1500, agi_accepts=350, targeted_store_v=456)
    assert paired_shapes == {'same-line':228, 'other-line':228, 'same-bank':0, 'alias':0, 'split':0, 'store-read':0}
    verify, vst = load(core/'verify-closed.json'), load(core/'verify-started.json')
    assert verify['pins_unchanged'] and verify['canonical_gate_native_exit'] == 2 and not verify['canonical_gate_passed']
    assert not verify['masks_or_goldens_or_bands_changed']
    owner('ventium-l1-write-kind-verify-oct11.service', vst['invocation'], 1)
    pins.update(vst['pins'])
    cycles = sorted((core/'generic-work').glob('*.cycle_rtl.vtrace'))
    assert len(cycles) == 20
    for p in cycles:
        q = parent/'generic-work'/p.name
        assert tracefmt.read_trace(str(p)).records == tracefmt.read_trace(str(q)).records
        pins.update({str(f):sha(f) for f in (p,q)})
    for p in (Path(__file__), Path(__file__).with_name('audit_next_query_payload.py'),
              core/'build-closed.json', core/'build-started.json', core/'verify-closed.json',
              core/'verify-started.json', root/'leaf-r1/closed.json'):
        pins[str(p)] = sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    result = dict(audit_complete=True, model_sha256=built['binary_sha256'], pins=pins, retained_owners=owners,
        counts=counts, paired_shapes=paired_shapes, all_20_canonical_cycle_streams_identical=True,
        canonical_gate_passed=False, gameplay_ipc=None, standard_suite=False, physical_board=False,
        fault_sweep=False, reset_sweep=False, timing_mhz=None)
    with (root/'audit.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','retained_owners')},indent=2))


if __name__ == '__main__': main()
