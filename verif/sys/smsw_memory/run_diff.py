"""Full system-state differential gate for the 88 cold-boot SMSW witnesses.

Goldens use the existing QEMU producer unchanged. Checks use the existing
comparator without extra masks, record trimming or cycle-band changes. Native
guest success is required separately from trace equality. This initial corpus
does not cover CPL3, V86 or page-fault behavior and is not suite acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

from run_probe import HERE, REPO, EXTERNAL, QEMU, sha
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt


def save(path, value):
    with path.open('x') as stream:
        json.dump(value,stream,indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('golden','check'))
    parser.add_argument('--root',required=True,type=Path)
    parser.add_argument('--probes',required=True,type=Path)
    parser.add_argument('--goldens',type=Path)
    parser.add_argument('--model',type=Path)
    args = parser.parse_args()
    root = args.root.absolute()
    assert root.parent.resolve(strict=True).is_relative_to(EXTERNAL)
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == EXTERNAL
    assert shutil.disk_usage(EXTERNAL).free > 4*1024**3 + 128*1024**2
    probes = args.probes.resolve(strict=True)
    audited = json.loads((probes/'audit.json').read_text())
    assert audited['passed'] and audited['missing_opcode_cases'] == 80 and audited['mov_controls'] == 8
    assert all(sha(path) == value for path,value in audited['artifacts'].items())
    old = json.loads((probes/'closed.json').read_text())
    pins = {str(path):sha(path) for path in (Path(__file__),HERE/'run_probe.py',QEMU,
        REPO/'verif/qemu-trace/gen_trace.py',REPO/'verif/diff/tracefmt.py',
        REPO/'verif/diff/compare.py',probes/'audit.json',probes/'closed.json')}
    golden_root = None
    if args.action == 'check':
        assert args.model and args.goldens
        model = args.model.resolve(strict=True)
        golden_root = args.goldens.resolve(strict=True)
        done = json.loads((golden_root/'closed.json').read_text())
        assert done['passed'] and done['action'] == 'golden' and len(done['rows']) == 88
        assert all(sha(path) == value for path,value in done['artifacts'].items())
        pins.update(done['artifacts'])
        pins[str(golden_root/'closed.json')] = sha(golden_root/'closed.json')
        pins[str(model)] = sha(model)
    cpus = sorted(os.sched_getaffinity(0))[:2]
    assert len(cpus) == 2
    affinity = ','.join(map(str,cpus))
    env = {key:value for key,value in os.environ.items()
           if not key.startswith(('VEN_','VENTIUM_','TB_','AXI_','QEMU_'))}
    env.update(AXI_RLAT='7',AXI_WLAT='7')
    root.mkdir()
    save(root/'started.json',dict(pins=pins,action=args.action,affinity=cpus,
                                 invocation=os.getenv('INVOCATION_ID')))

    def run(name,command,leaf_name,seconds=20):
        actual = ['taskset','-c',affinity,'timeout','--signal=TERM','--kill-after=2s',
                  str(seconds)+'s',*map(str,command)]
        observed = {}
        save(root/(name+'.command.json'),dict(argv=actual))
        with (root/(name+'.log')).open('x') as stream:
            process = subprocess.Popen(actual,env=env,stdout=stream,stderr=subprocess.STDOUT)
            try:
                while process.poll() is None:
                    queue = [process.pid]
                    while queue:
                        pid = queue.pop()
                        try:
                            proc = Path('/proc')/str(pid)
                            queue.extend(map(int,(proc/'task'/str(pid)/'children').read_text().split()))
                            exe = (proc/'exe').readlink().name
                            if exe == leaf_name:
                                seen = sorted(os.sched_getaffinity(pid))
                                assert seen == cpus, (pid,exe,seen,cpus)
                                observed[pid] = dict(exe=exe,affinity=seen)
                        except (FileNotFoundError,ProcessLookupError):
                            pass
                    time.sleep(0.005)
                code = process.wait()
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
        save(root/(name+'.native.json'),dict(exit=code,observed=observed))
        assert observed, ('native leaf affinity was not observed',name,leaf_name)
        return code

    result = dict(passed=False,action=args.action,rows=[],errors=[],standard_suite=False,
                  hardware_acceptance=False,gameplay_ipc=None)
    begin = time.monotonic()
    try:
        for index,row in enumerate(old['rows']):
            c = row['case']
            name = f'm{c["MODE"]}-a{c["ADDR32"]}-o{c["OP32"]}-d{c["OFFSET"]}-b{c["BASE"]}-c{c["CONTROL"]}'
            image = probes/(name+'.bin')
            assert sha(image) == row['image_sha256']
            pins[str(image)] = sha(image)
            out = root/(name+'.vtrace')
            if args.action == 'golden':
                command = ['python3',REPO/'verif/qemu-trace/gen_trace.py','--system',
                    '--qemu',QEMU,'--cpu','pentium','--image',image,'--image-mode','bios',
                    '--max-insn','2000','--port',str(12473+index),'--out',out]
                code = run(name,command,'qemu-system-i386')
                assert code == 0
                assert 'guest exited' in (root/(name+'.log')).read_text()
            else:
                code = run(name,[model,'--system','--cosim','--cycle-func','--l1-axi',
                    '--image',image,'--out',out,'--max-insn','2000','--max-cycles','1000000',
                    '--quiesce','4096','+ven_faultlog','+ven_seglog'],model.name)
                assert code == 133, (name,code,'native guest failed')
                log = (root/(name+'.log')).read_text()
                assert 'isa-debug-exit' in log and '[FAULT] vec=' not in log
                compare = ['python3',REPO/'verif/diff/compare.py','--mode','func',golden_root/out.name,out]
                rc = run(name+'-compare',compare,Path(sys.executable).resolve().name)
                assert rc == 0, (name,'differential mismatch')
                text = (root/(name+'-compare.log')).read_text()
                assert 'sys compared: True' in text and 'RESULT: EQUIVALENT' in text
            trace = tracefmt.read_trace(str(out))
            assert trace.sys and trace.mode == 'func' and 20 < len(trace.records) < 2000
            assert int(trace.records[-1]['eax'],16) & 255 == 0x42
            result['rows'].append(dict(name=name,records=len(trace.records),native_exit=code,
                                       trace_sha256=sha(out)))
        assert len(result['rows']) == 88
        result['passed'] = True
    except Exception as error:
        result['errors'].append(repr(error))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    result['artifacts'] = {str(path):sha(path) for path in root.iterdir() if path.is_file()}
    save(root/'closed.json',result)
    print(json.dumps({key:value for key,value in result.items() if key not in ('rows','artifacts')}))
    print('cases',len(result['rows']),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
