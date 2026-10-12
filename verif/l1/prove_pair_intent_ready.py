"""Check an intent-qualified readiness cut without modifying candidate RTL.

The source-extracted native miter retains all guards except next-lookup conflict
in the proposed *intent-only* result. The ordinary readiness port must not be
replaced globally: a deliberate counterexample is required. Symbolic checks
cover the guarded core request and cache ACK, not sequential cache correctness.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import time

PARENT = '182856870bdf5627a2c0c48180fbb2a2a604b679728b40d53e9811bb1df31d37'
GUARD = '''`ifdef VEN_PIPE_MEM_CHAIN
        && (c_pair_intent || !(c_next_req && rd_match))
`endif
'''
FEATURES = ('VEN_P54_LOAD_STORE_PAIR', 'VEN_PIPE_MEM_CHAIN', 'VEN_L1D_CODE_BUFFER')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def extract(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('fresh-pair L1 source drift')
    matches = re.findall(r'  assign c_pair_ready = .*?;\n', source, re.S)
    if len(matches) != 1 or matches[0].count(GUARD) != 1:
        raise ValueError('readiness/intent guard drift')
    old = matches[0]
    return old, old.replace('assign c_pair_ready =', 'assign pair_intent_ready =').replace(GUARD, '')


def symbolic():
    flags = ('common we credit load_store chain intent owned resident early code '
             'code_buffer next_req rd core_offer l1_req seam_qual pair_req ack tail').split()
    text = '(set-logic QF_BV)\n'+''.join(f'(declare-const {n} Bool)\n' for n in flags)
    terms = {
        'read': '(and owned resident (not early) (not (and code_buffer code)))',
        'base': '(ite load_store (ite we credit read) (and we credit))',
        'old': '(and common (ite load_store (ite we credit (and read '
               '(or (not chain) intent (not (and next_req rd))))) (and we credit)))',
        'fast': '(and common base)',
        'core_gate': '(and core_offer l1_req seam_qual)',
        'old_request': '(and core_gate old)',
        'new_request': '(and core_gate fast)',
        'old_ack': '(and pair_req old ack tail)',
        'new_ack': '(and pair_req fast ack tail)',
    }
    for name, body in terms.items():
        text += f'(define-fun {name} () Bool {body})\n'
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve(); source = args.source.resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    old, fast = extract(source.read_text())
    # The cofactor changes exactly one conjunct, never the ordinary output.
    assert fast.replace('assign pair_intent_ready =', 'assign c_pair_ready =').replace(
        '       )) &&', GUARD+'       )) &&') == old
    try:
        extract(source.read_text()+'\n')
    except ValueError:
        pass
    else:
        raise AssertionError('source drift accepted')
    template = Path(__file__).with_name('tb_pair_intent_ready.sv')
    pins = {str(p.resolve()): sha(p) for p in (
        Path(__file__), template, source, Path('/usr/bin/iverilog'), Path('/usr/bin/vvp'), Path('/usr/bin/z3'))}
    text = template.read_text()
    for marker, value in (('  // @@ORIGINAL@@', old.rstrip()), ('  // @@COFACTOR@@', fast.rstrip())):
        assert text.count(marker) == 1
        text = text.replace(marker, value)
    root.mkdir()
    def save(name, value):
        with (root/name).open('x') as stream:
            json.dump(value, stream, indent=2)
    with (root/'miter.sv').open('x') as stream: stream.write(text)
    pins[str(root/'miter.sv')] = sha(root/'miter.sv')
    save('started.json', dict(pins=pins,invocation=os.environ.get('INVOCATION_ID'),
        source= str(source), candidate_rtl_changed=False, affinity=sorted(os.sched_getaffinity(0))))
    start = time.monotonic()

    def native(bits):
        label = ''.join(map(str,bits)); work=root/label; work.mkdir()
        defines = [f'-D{name}' for name,enabled in zip(FEATURES,bits) if enabled]
        command = ['/usr/bin/iverilog','-g2012','-s','tb_pair_intent_ready',*defines,
                   '-o',str(work/'miter'),str(root/'miter.sv')]
        rows=[]
        for phase,cmd in (('compile',command),('simulate',['/usr/bin/vvp',str(work/'miter')])):
            with (work/(phase+'.log')).open('x') as stream:
                result=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,timeout=30)
            rows.append(dict(phase=phase,command=cmd,native_exit=result.returncode))
            assert result.returncode==0,(label,phase)
        log=(work/'simulate.log').read_text()
        matches=re.findall(r'INTENT-READY-OK checks=(\d+) qualified=(\d+) ready=(\d+) outside_difference=(\d+)',log)
        assert len(matches)==1 and not re.search(r'FATAL|ERROR',log)
        counts=dict(zip(('checks','qualified','ready','outside_difference'),map(int,matches[0])))
        assert counts['checks']==393216 and counts['qualified']==327680 and counts['ready']>0
        assert bool(counts['outside_difference']) == bool(bits[0] and bits[1])
        return dict(profile=label,defines=defines,native=rows,counts=counts,
            artifact_pins={str(p):sha(p) for p in work.iterdir() if p.is_file()})

    with ThreadPoolExecutor(max_workers=4) as workers:
        profiles=list(workers.map(native,itertools.product((0,1),repeat=3)))
    queries = [
        ('qualified-ready','(and intent (not (= old fast)))','unsat'),
        ('core-request','(and (= intent (and core_offer l1_req)) (not (= old_request new_request)))','unsat'),
        ('cache-ack','(and (=> pair_req intent) (not (= old_ack new_ack)))','unsat'),
        ('unsafe-global-replacement','(not (= old fast))','sat'),
        ('lost-credit','(and intent common we (not credit) (not old))','sat'),
        ('lost-residency','(and intent common load_store (not we) owned (not resident) (not early) (not code) (not old))','sat'),
        ('lost-ownership','(and intent common load_store (not we) (not owned) resident (not early) (not code) (not old))','sat'),
        ('missing-intent-propagation','(and core_gate (not intent) (not (= old_request new_request)))','sat'),
    ]
    proofs=[]
    for name,formula,expected in queries:
        problem=symbolic()+'(assert '+formula+')\n(check-sat)\n'
        with (root/(name+'.smt2')).open('x') as stream: stream.write(problem)
        result=subprocess.run(['/usr/bin/z3','-in','-smt2'],input=problem,text=True,capture_output=True,timeout=10)
        for suffix,value in (('stdout',result.stdout),('stderr',result.stderr)):
            with (root/(name+'.'+suffix)).open('x') as stream: stream.write(value)
        assert result.returncode==0 and not result.stderr and result.stdout.strip()==expected,(name,result)
        proofs.append(dict(name=name,native_exit=0,result=expected))
    assert all(sha(p)==h for p,h in pins.items())
    done=dict(passed=True,pins_unchanged=True,profiles=profiles,queries=proofs,
        checks=sum(p['counts']['checks'] for p in profiles),seconds=time.monotonic()-start,
        candidate_rtl_changed=False,sequential_cache_proof=False,hardware_acceptance=False,
        standard_suite=False,gameplay_ipc=None)
    save('closed.json',done)
    print(json.dumps({k:v for k,v in done.items() if k!='profiles'},indent=2),flush=True)


if __name__=='__main__':main()
