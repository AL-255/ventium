"""Source-linked native read/write wait miter, with required negative controls.

The complete actual request and S_PIPE bus arms establish direction. Downstream
translation cancellation and the existing seam ACK contract remain abstract
inputs; whole-core/cache correctness must be checked separately.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import time
import traceback

import prepare_pipe_wait_read_ack as recipe
import run_payload_fetch_kind_leaf as extraction

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
MODEL = 'cce12fc71c394b5a154e8bad108a3b88ab1d1acccba000f1961a26ea4f19d07d'
SAMPLES = 12584960


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def assignment(source, name):
    matches = re.findall(r'^  assign '+name+r'\s*=.*?;', source, re.M | re.S)
    if len(matches) != 1:
        raise ValueError('ambiguous assignment: '+name)
    return matches[0]


def fixture(core, bus, template):
    changed = recipe.transform(core)
    frontend, requests, branch = extraction.extract(core, bus)
    read_ack = '  assign mem_read_ack = bus_read_ack && !fx_hold_e;'
    fallback = '  assign mem_read_ack = mem_ack;'
    assert core.count(read_ack) == core.count(fallback) == 1
    candidate = assignment(changed, 'pipe_mem_wait').replace('pipe_mem_wait', 'new_wait')
    candidate = candidate.replace('mem_read_ack', 'selected_read_ack')
    candidate = candidate.replace('mem_ack', 'selected_store_ack')
    candidate = candidate.replace('pipe_store_req', 'selected_store_req')
    replacements = dict(FRONTEND=frontend, REQUESTS=requests, BRANCH=branch,
        FRAGMENT=assignment(core, 'fx_hold_e'), ACK=assignment(core, 'mem_ack'),
        READ_ACK=read_ack, FALLBACK_ACK=fallback,
        REFERENCE=assignment(core, 'pipe_mem_wait').replace('pipe_mem_wait', 'old_wait'),
        CANDIDATE=candidate)
    for key, value in replacements.items():
        token = '\n'+key+'\n'
        assert template.count(token) == 1
        template = template.replace(token, '\n'+value+'\n')
    return template


def check_receipt(root):
    start, closed = [json.loads((root/n).read_text()) for n in ('started.json', 'closed.json')]
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert not closed['whole_core'] and closed['memory_events']['oom_kill'] == '0'
    assert all(closed['memory_events'][k] == '0' for k in ('oom', 'oom_group_kill'))
    assert [(r['profile'], r['mutant']) for r in closed['rows']] == [
        (p, m) for p in ('early', 'fallback') for m in range(5)]
    for p in ('early', 'fallback'):
        build = closed['builds'][p]
        assert build['native_exit'] == 0 and build['actual_wait']
        assert build['affinity'] == list(range(32))
        assert sha(root/(p+'-build.log')) == build['log_sha256']
    for row in closed['rows']:
        assert row['actual_wait'] and row['affinity'] == [13]
        log = root/(row['profile']+'-'+str(row['mutant'])+'.log')
        assert sha(log) == row['log_sha256']
        if row['mutant']:
            assert row['native_exit'] != 0 and 'PIPE-WAIT-EQUIV' in log.read_text()
        else:
            assert row['native_exit'] == 0 and row['counts']['samples'] == SAMPLES
            assert all(row['counts'].values())
    pins = start['pins'] | closed['artifacts']
    assert all(sha(p) == h for p, h in pins.items())
    return pins | {str(root/'started.json'): sha(root/'started.json'),
                   str(root/'closed.json'): sha(root/'closed.json')}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for key in ('parent', 'out'): ap.add_argument('--'+key, required=True, type=Path)
    a = ap.parse_args()
    parent, out = a.parent.resolve(strict=True), a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    assert os.sched_getaffinity(0) == set(range(32)) and os.environ['INVOCATION_ID']
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode == 1
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    old, built = [json.loads((parent/n).read_text()) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged']
    assert sha(parent/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    core, bus = [parent/'candidate/rtl/core'/n for n in ('core.sv','core_bus_driver.svh')]
    assert all(sha(p) == old['pins'][str(p)] for p in (core, bus))
    changed = recipe.transform(core.read_text())
    definitions = old['definitions']
    assert len(definitions) == len(set(definitions)) == 153
    assert {'VEN_FP_LOAD_EARLY_CMD','VEN_P54_LOAD_STORE_PAIR','VEN_X87_MF_STRICT'} <= set(definitions)
    template = HERE/'pipe_wait_read_ack_leaf.svh'
    out.mkdir()
    (out/'core.sv').write_text(changed)
    tb = out/'tb_pipe_wait_read_ack.sv'
    tb.write_text(fixture(core.read_text(),bus.read_text(),template.read_text()))
    paths = (Path(__file__), Path(recipe.__file__), Path(extraction.__file__), template,
             core,bus,tb,out/'core.sv',parent/'obj/tb_ventium',
             parent/'build-started.json',parent/'build-closed.json',
             Path(os.environ['VENTIUM_VERILATOR_BIN']),REPO/'tools/build_scope.sh')
    pins = {str(p.resolve()): sha(p) for p in paths}
    group = Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().strip().split('::',1)[1].lstrip('/')
    def save(name, value):
        with (out/name).open('x') as f: json.dump(value, f, indent=2)
    def run(name, command, affinity, timeout):
        command = list(map(str,command))
        with (out/(name+'.log')).open('x') as f:
            child = subprocess.Popen(command, stdout=f, stderr=subprocess.STDOUT,
                                     pass_fds=(9,), start_new_session=True)
            try:
                # Pin before exec for a native child; the guarded compiler keeps
                # its 32-CPU domain. Verify the actual child, not unit properties.
                os.sched_setaffinity(child.pid, affinity)
                observed = sorted(os.sched_getaffinity(child.pid))
                assert observed == sorted(affinity)
                code = child.wait(timeout=timeout)
            except BaseException:
                if child.poll() is None: os.killpg(child.pid,signal.SIGKILL)
                child.wait()
                raise
        return dict(command=command,native_exit=code,actual_wait=True,pid=child.pid,
                    affinity=observed,log_sha256=sha(out/(name+'.log')))
    save('started.json',dict(pins=pins,definitions=definitions,parent=str(parent),
        invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0)),cgroup=str(group)))
    result = dict(passed=False,errors=[],rows=[],builds={},whole_core=False,
                  gameplay_ipc=None,standard_suite=False,hardware_acceptance=False)
    begin = time.monotonic()
    try:
        for profile in ('early','fallback'):
            defs = definitions if profile == 'early' else [d for d in definitions if d!='VEN_FP_LOAD_EARLY_CMD']
            command = [REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-j','32',
                '-Wno-fatal','-Wno-UNUSED',*['-Werror-'+w for w in
                ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '--top-module','tb_pipe_wait_read_ack','--Mdir',out/profile,
                *['+define+'+d for d in defs],tb]
            result['builds'][profile] = run(profile+'-build',command,set(range(32)),180)
            assert result['builds'][profile]['native_exit'] == 0
            binary = out/profile/'Vtb_pipe_wait_read_ack'
            for mutant in range(5):
                name = profile+'-'+str(mutant)
                row = run(name,['taskset','-c','13',binary,'+mutant='+str(mutant)],{13},120)
                row.update(profile=profile,mutant=mutant,binary_sha256=sha(binary))
                log = (out/(name+'.log')).read_text()
                if mutant:
                    assert row['native_exit'] != 0 and 'PIPE-WAIT-EQUIV' in log
                else:
                    m = re.search(r'^PIPE-WAIT-OK (.+)$',log,re.M)
                    assert row['native_exit'] == 0 and m
                    row['counts'] = {k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',m[1])}
                    assert row['counts']['samples'] == SAMPLES and all(row['counts'].values())
                result['rows'].append(row)
        result['passed'] = True
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
        memory_events=dict(line.split() for line in (group/'memory.events').read_text().splitlines()),
        artifacts={str(p):sha(p) for p in out.iterdir() if p.is_file()})
    result['passed'] &= result['pins_unchanged'] and all(result['memory_events'][k]=='0'
                         for k in ('oom','oom_kill','oom_group_kill'))
    save('closed.json',result)
    if result['passed']: check_receipt(out)
    print(json.dumps({k:v for k,v in result.items() if k not in ('artifacts','builds','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
