"""Cold paged selector tests: distinct data, high bytes, immediate/held owners.

Reuse the complete QEMU-state and per-retirement-clock comparisons. Identical
control/candidate paths qualify fixtures only, never an implementation change.
Only tiny guest assembly and already-built simulators run; no RTL/C++ build.
"""
import ast
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/l1'))
import run_l1_capture_cut_system as original

BACKEND_SHA = 'eef20073c94274da3aa01862d45a78d8751bd9a92594c591544608376ce0e9ef'
PATTERNS = (
    ('now-wide', 'movl (%eax),%edx', 'movl 4(%eax),%ebx'),
    ('now-low', 'movb (%eax),%dl', 'movb 31(%eax),%bl'),
    ('now-high', 'movb (%eax),%dl', 'movb 31(%eax),%bh'),
    ('held-wide', 'movl (%eax),%edx', 'movl 4(%edi),%ebx'),
    ('held-high', 'movb (%eax),%dl', 'movb 31(%edi),%bh'),
    ('same-bank', 'movl (%eax),%edx', 'movl (%eax),%ebx'),
    ('split', 'movl (%eax),%edx', 'movl 31(%eax),%ebx'),
    ('word', 'movl (%eax),%edx', 'movw 4(%eax),%bx'),
)


def fixture(text, label, u, v):
    assert text.count('movl $0x11223344,(0x3000+p*4)') == 1
    text = text.replace('movl $0x11223344,(0x3000+p*4)',
                        'movl $(0xa1b2c300+p*0x01020305),(0x3000+p*4)')
    assert text.count('movl $7,%ebx') == 1
    text = text.replace('movl $7,%ebx', 'movl $0x5a69c3d2,%ebx')
    a, b = text.index('hot_u:\n'), text.index('    incl %ebp\n')
    text = text[:a]+'hot_u:\n    '+u+'\nhot_load:\n    '+v+'\n'+text[b:]
    if label.startswith('now-'):
        assert text.count('    jmp hot_u\n') == 2
        text = text.replace('    jmp hot_u\n', '    jmp warm_u\n')
        text = text.replace('    .balign 32,0x90\n',
            'warm_u:\n    movl (%eax),%edx\n    addl %edx,%edx\n'
            '    jmp hot_u\n    .balign 32,0x90\n', 1)
    return text


def observed_call(command, env, stdout, stderr, receipt):
    """Observe actual simulator PID/argv/affinity, not the timeout wrapper."""
    actual = {}
    child = subprocess.Popen(command, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
    begin = time.monotonic()
    error = None
    try:
        while child.poll() is None:
            pending = [child.pid]
            while pending:
                pid = pending.pop()
                proc = Path('/proc')/str(pid)
                try:
                    pending.extend(map(int, (proc/'task'/str(pid)/'children').read_text().split()))
                    argv = [os.fsdecode(s) for s in (proc/'cmdline').read_bytes().split(b'\0')[:-1]]
                    if argv != command[3:]:
                        continue
                    row = dict(pid=pid, argv=argv, exe=str((proc/'exe').resolve(strict=True)),
                        affinity=sorted(os.sched_getaffinity(pid)), cgroup=(proc/'cgroup').read_text(),
                        starttime=(proc/'stat').read_text().rsplit(')', 1)[1].split()[19])
                except (FileNotFoundError, ProcessLookupError):
                    continue
                assert row['affinity'] == [12]
                assert row['cgroup'] == Path('/proc/self/cgroup').read_text()
                actual[(pid, row['starttime'])] = row
            assert time.monotonic()-begin < 50, 'native observation deadline'
            time.sleep(.001)
        child.wait()
        if Path(command[3]).name == 'tb_ventium':
            assert actual, 'simulator child affinity was not observed'
    except BaseException as exc:
        error = repr(exc)
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
        child.wait()
        original.save(receipt, dict(native_exit=child.returncode, actual=list(actual.values()),
            launcher_reaped=not (Path('/proc')/str(child.pid)).exists(), error=error))
    assert error is None, error
    return SimpleNamespace(returncode=child.returncode)


def derive():
    source = Path(original.__file__)
    assert original.sha(source) == BACKEND_SHA
    text = source.read_text()

    def replace(old, new):
        nonlocal text
        assert text.count(old) == 1, old
        text = text.replace(old, new)

    replace('HERE=Path(__file__).resolve().parent', 'HERE=Path('+repr(str(source.parent))+')')
    replace("with source.open('x') as f:f.write(text[:a]+'hot_u:\\n    '+u+'\\nhot_load:\\n    '+v+'\\n'+text[b:])",
            "with source.open('x') as f:f.write(fixture(text,label,u,v))")
    replace("p=subprocess.run(command,env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),\n"
            "                             stdout=stdout,stderr=stderr)",
            "p=observed_call(command,dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),\n"
            "                            stdout,stderr,leaf/(label+'.native.json'))")
    replace("'--quiesce','4096','+ven_faultlog'", "'--quiesce','4096','+ven_faultlog','+ven_pair_now_read_ack_witness'")
    replace("traces={}; clocks={}", "traces={}; clocks={}; immediate={}")
    anchor = "                    assert not native.FATAL.search(stdout) and not native.FATAL.search(stderr)"
    replace(anchor, anchor+"\n                    immediate[mode]=sum(int(pc,16)==symbols['hot_u'] for pc in\n"
            "                        re.findall(r'^\\[PAIR-NOW-READ-ACK\\] pc=([0-9a-f]+) ',stdout,re.M))")
    replace("assert clocks['cycle']==clocks['cycle-func']",
            "assert clocks['cycle']==clocks['cycle-func']\n                assert immediate['cycle']==immediate['cycle-func']")
    replace("if label in ('same-bank','split'): assert memory_v==0,(case,name,memory_v)",
            "if label in ('same-bank','split','word'): assert memory_v==0,(case,name,memory_v)\n"
            "                if not label.startswith('now-'): assert immediate['cycle']==0,(case,name,immediate)")
    replace("records=len(traces['cycle']),memory_v=memory_v,",
            "records=len(traces['cycle']),memory_v=memory_v,immediate=immediate['cycle'],")
    replace('for o in (0,1,7,15,28,31)', 'for o in (0,31)')
    replace('ThreadPoolExecutor(max_workers=4)', 'ThreadPoolExecutor(max_workers=1)')
    replace("    result['seconds']=time.monotonic()-start", """    result['fixture_only']=models['control']==models['candidate']
    result['coverage']={label:dict(paired=sum(r['memory_v'] for r in rows if r['model']=='candidate' and r['case'][0]==label),
        immediate=sum(r['immediate'] for r in rows if r['model']=='candidate' and r['case'][0]==label))
        for label,_,_ in PATTERNS}
    for label,count in result['coverage'].items():
        if label.startswith('now-'):
            result['passed'] &= count['immediate']>=24 and count['paired']>=count['immediate']
        elif label.startswith('held-'):
            result['passed'] &= count['paired']>=24 and count['immediate']==0
        else:
            result['passed'] &= count['paired']==count['immediate']==0
    result['seconds']=time.monotonic()-start""")
    ast.parse(text)
    return text


def main():
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = Path(sys.argv[sys.argv.index('--out')+1]).resolve()
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert os.sched_getaffinity(0) == {12} and shutil.disk_usage(scratch).free > 5*1024**3
    available = next(int(s.split()[1])*1024 for s in Path('/proc/meminfo').read_text().splitlines()
                     if s.startswith('MemAvailable:'))
    assert available > 4*1024**3
    group = Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    assert (group/'memory.max').read_text().strip() == str(1024**3)
    assert (group/'memory.swap.max').read_text().strip() == '0'
    out.mkdir()
    driver = out/'driver.py'
    with driver.open('x') as stream: stream.write(derive())
    pins = {str(p): original.sha(p) for p in (Path(__file__).resolve(), Path(original.__file__), driver)}
    spec = importlib.util.spec_from_file_location('v_load_system_backend', driver)
    backend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backend)
    backend.fixture, backend.observed_call, backend.PATTERNS = fixture, observed_call, PATTERNS
    sys.argv[sys.argv.index('--out')+1] = str(out/'matrix')
    result = backend.main()
    stable = all(original.sha(p) == h for p,h in pins.items())
    events = dict(row.split() for row in (group/'memory.events').read_text().splitlines())
    no_oom = all(events[k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    original.save(out/'adapter.json', dict(pins=pins,pins_unchanged=stable,native_runner_exit=result,
        memory_events=events,no_oom=no_oom,result_sha256=original.sha(out/'matrix/closed.json')))
    assert stable and no_oom
    return result


if __name__ == '__main__':
    raise SystemExit(main())
