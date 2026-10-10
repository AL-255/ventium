#!/usr/bin/env python3
"""Cold-reset, QEMU-compared 16-bit fetch corpus with actual 32-bit U/V witness.

Four-byte requests must not change instruction semantics, page transitions or
architectural state. Tests use real execution, not STEP or saved-state injection.
Full standard-suite and gameplay acceptance remain separate.
"""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import check_faultlog
import compare
import tracefmt
spec = importlib.util.spec_from_file_location('native', REPO/'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as f:
        json.dump(value, f, indent=2)


def assign_gdb_ports(cases, base, ephemeral_start):
    """Unique per-case ports outside the host's auto-assigned client range."""
    assert cases and len(set(cases))==len(cases), 'empty or duplicate cases'
    assert 1024 <= base and base+len(cases) <= ephemeral_start, 'GDB/ephemeral range overlap'
    return {case:base+i for i,case in enumerate(cases)}


def axi_activity(stdout):
    rows=re.findall(r'^\[L1DPERF\] fill cycles=(\d+) backing-wait=(\d+) backing-ack=(\d+)$',stdout,re.M)
    assert len(rows)==1 and int(rows[0][0])>0 and int(rows[0][2])>0, 'inactive/missing AXI backend'
    return tuple(map(int,rows[0]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--offset', type=int, action='append')
    parser.add_argument('--full', action='store_true')
    parser.add_argument('--cache-policy', choices=('reset','enabled'), default='enabled')
    parser.add_argument('--scenario', choices=('demand','smc'), default='demand')
    parser.add_argument('--port-base',type=int,default=20000)
    parser.add_argument('--workers', type=int, default=4, choices=range(1, 33))
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    assert shutil.disk_usage(scratch).free > 1024**3
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    if args.workers > 4:
        assert os.environ.get('VENTIUM_BUILD_SCOPE_PROFILE') == 'ipc_parallel32'
    offsets = sorted(set(args.offset if args.offset is not None else (range(32) if args.full else [0,31])))
    assert offsets and all(0 <= x < 32 for x in offsets)
    args.out.mkdir()
    models = dict(control=args.control.resolve(strict=True), candidate=args.candidate.resolve(strict=True))
    profiles, pins = {}, {}
    for name, model in models.items():
        stamp = model.parent/'Vventium_top__verFiles.dat'
        command = next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
        defs = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_FE_PIPE',
                'VEN_SEG_ENFORCE', 'VEN_IC_BRAM', 'VEN_L1D_PERF'} <= defs
        assert not {'VEN_SYS_FASTPATH_ALL', 'VTM_NO_DPI', 'SYNTHESIS', 'VEN_UOPCACHE'} & defs
        profiles[name] = defs
        pins.update({str(p): sha(p) for p in (model, stamp)})
        receipt = model.parent.parent/'build-started.json'
        closure = json.loads(receipt.read_text())['pins']
        assert all(sha(p)==h for p,h in closure.items()), 'changed source closure'
        pins.update(closure)
        pins[str(receipt)] = sha(receipt)
    assert profiles['candidate'] == profiles['control'] | {'VEN_SFETCH16_DEMAND'}
    source = HERE/('sfetch16-demand.S' if args.scenario=='demand' else 'sfetch16-smc.S')
    if args.scenario=='smc':
        assert args.cache_policy=='enabled', 'SMC tests require real cache-enabled execution'
    linker = REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__), source, linker, qemu, REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py', REPO/'verif/diff/compare.py',
              REPO/'verif/sys/run-native-system.py', REPO/'verif/sys/check_faultlog.py'):
        pins[str(p)] = sha(p)
    shapes = [(0,p) for p in (0,3,4,7,11,14)] + [(1,p) for p in (0,1,2,5,9,12)] + [(2,p) for p in (0,1,2)]
    if not args.full:
        shapes = [(0,0), (0,14), (1,2), (2,2)]
    if args.scenario=='smc':
        shapes = [(1,p) for p in ((0,1,2,5,9,12) if args.full else (0,12))]
    cases = [(m,k,p,o,t) for m in range(3) for k,p in shapes for o in offsets for t in (0,1)]
    ephemeral_start=int(Path('/proc/sys/net/ipv4/ip_local_port_range').read_text().split()[0])
    ports=assign_gdb_ports(cases,args.port_base,ephemeral_start)
    save(args.out/'started.json', dict(pins=pins, cases=cases, models={k:str(v) for k,v in models.items()},
        invocation=os.environ.get('INVOCATION_ID'), unix=time.time(), workers=args.workers,
        cache_policy=args.cache_policy,scenario=args.scenario,port_base=args.port_base))
    # Retain exact executed fixture/driver bytes even if a later test adds
    # coverage. Live pins still must remain unchanged throughout THIS run.
    shutil.copyfile(Path(__file__),args.out/'executed-runner.py')
    shutil.copyfile(source,args.out/'executed-fixture.S')
    shutil.copyfile(REPO/'verif/qemu-trace/gen_trace.py',args.out/'executed-generator.py')
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VTM_', 'TB_', 'QEMU_', 'AXI_'))}
    env.update(TMPDIR=str(args.out), PYTHONDONTWRITEBYTECODE='1')
    # A golden job owns a Python driver, timeout and multi-threaded QEMU, not
    # just one PID. Keep all 32 independent cases queued without overflowing
    # the reviewed scope's 128-TID ceiling. Never expand/bypass that ceiling.
    slots = threading.BoundedSemaphore(min(args.workers,8))
    cgroup = Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().strip().split('::',1)[1].lstrip('/')
    resources = lambda: {name:(cgroup/name).read_text().strip()
                        for name in ('memory.current','memory.peak','memory.events','pids.current','pids.max','pids.events','cgroup.procs')}
    resource_before=resources()
    save(args.out/'resources-before.json',resource_before)

    def run(leaf, name, command, expected=0, latency=0):
        command = ['timeout', '--signal=TERM', '--kill-after=3s', '45s', *map(str, command)]
        save(leaf/(name+'.command.json'), command)
        with (leaf/(name+'.stdout')).open('x') as out, (leaf/(name+'.stderr')).open('x') as err:
            with slots:
                rc = subprocess.run(command, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                                    stdout=out, stderr=err, pass_fds=(9,)).returncode
        save(leaf/(name+'.exit.json'), dict(native_exit=rc))
        assert rc == expected, (leaf.name, name, rc, expected)
        return (leaf/(name+'.stdout')).read_text(), (leaf/(name+'.stderr')).read_text()

    def check(case):
        mode, kind, prefix, offset, tail = case
        leaf = args.out/f'm{mode}-k{kind}-p{prefix}-o{offset}-t{tail}'
        leaf.mkdir()
        obj, elf, image = [leaf/('fixture.'+ext) for ext in ('o', 'elf', 'bin')]
        run(leaf, 'assemble', ['gcc', '-m32', '-nostdlib', '-ffreestanding', '-fno-pie', '-fno-pic',
            f'-DMODE={mode}', f'-DKIND={kind}', f'-DPREFIX={prefix}', f'-DOFFSET={offset}', f'-DPAGE_TAIL={tail}',
            f'-DCACHE_ENABLED={int(args.cache_policy=="enabled")}',
            '-c', source, '-o', obj])
        run(leaf, 'link', ['gcc', '-m32', '-static', '-no-pie', '-nostdlib',
            '-Wl,-T,'+str(linker), '-Wl,--build-id=none', obj, '-o', elf])
        run(leaf, 'binary', ['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image])
        with slots:
            nm = subprocess.check_output(['nm', '-n', elf], text=True)
        symbols = {p[2]: int(p[0], 16) for line in nm.splitlines()
                   if len(p := line.split()) == 3 and p[0] != 'U'}
        assert image.stat().st_size == 65536 and symbols['hot_instruction'] % 32 == offset
        assert symbols['hot_end']-symbols['hot_instruction'] == prefix+[1,3,13][kind] <= 15
        hot_pc = symbols['hot_instruction']-0xf0000
        hot_cs = 0xf000 if mode==0 else 0x18
        if args.scenario=='smc':
            hot_pc,hot_cs = symbols['hot_instruction'],symbols['hot_cs']
            assert hot_cs==(0x900 if mode==0 else 0x28)
            assert symbols['hot_physical']==0x9000+hot_pc
        is_hot = lambda r: int(r['pc'],0)==hot_pc and int(r['cs'],0)==hot_cs
        if tail:
            assert symbols['hot_instruction'] % 4096 == 4096-32+offset
        run(leaf, 'free-qemu', [qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64', '-bios', image,
            '-display', 'none', '-serial', 'none', '-monitor', 'none', '-no-reboot', '-no-shutdown',
            '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], 133)
        port=ports[case]
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',port)) # fail explicitly if an unrelated owner is present
        golden_path = leaf/'golden.vtrace'
        run(leaf, 'golden', [sys.executable, '-B', REPO/'verif/qemu-trace/gen_trace.py', '--qemu', qemu,
            '--system', '--image', image, '--image-mode', 'bios', '--cpu', 'pentium',
            '--out', golden_path, '--max-insn', '2000', '--port', str(port)])
        gold = tracefmt.read_trace(str(golden_path))
        assert gold.mode == 'func' and gold.sys and 100 < len(gold.records) < 2000
        assert int(gold.records[-1]['eax'], 0) & 255 == 0x42
        assert all(all(k in r for k in tracefmt.SYS_CR) for r in gold.records)
        if args.cache_policy=='enabled':
            hot = [r for r in gold.records if is_hot(r)]
            assert len(hot)==16 and all(int(r['cr0'],0)&0x60000000==0 for r in hot)
        if args.scenario=='smc':
            assert [bytes.fromhex(r['bytes'])[:prefix+3] for r in hot] == [
                bytes([0x3e])*prefix+(bytes.fromhex('b83412') if i%2==0 else bytes.fromhex('909090'))
                for i in range(16)], 'golden did not execute both rewritten byte sequences'
            returns=[r for r in gold.records if int(r['pc'],0)==symbols['after_hot']-0xf0000 and
                     int(r['cs'],0)==(0xf000 if mode==0 else 0x18)]
            assert [int(r['eax'],0)&0xffff for r in returns]==[0x1234 if i%2==0 else 0x5678 for i in range(16)]
        measures = []
        for latency in (0,7):
            for name, model in models.items():
                stops, traces, backing = {}, {}, {}
                for observation in ('cycle-func','cycle'):
                    stem = f'{name}-lat{latency}-{observation}'
                    path = leaf/(stem+'.vtrace')
                    out, err = run(leaf, stem, [model, '--system', '--cosim', '--'+observation, '--l1-axi',
                        '--image', image, '--out', path, '--max-insn', '2000', '--max-cycles', '1000000',
                        '--quiesce', '4096', '+ven_faultlog'], 133, latency)
                    trace = tracefmt.read_trace(str(path))
                    traces[observation] = trace.records
                    backing[observation] = axi_activity(out)
                    assert [r['n'] for r in trace.records] == list(range(len(gold.records)))
                    assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]
                    check_faultlog.check_counts(check_faultlog.read_counts(out.splitlines()), {})
                    assert not native.FATAL.search(out) and not native.FATAL.search(err)
                    footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                                        r'after (\d+) retired in (\d+) clocks$', err, re.M)
                    assert len(footer) == 1 and int(footer[0][0]) == len(trace.records)
                    stops[observation] = int(footer[0][1])
                    if observation == 'cycle-func':
                        native.grade_native(trace,out,err,133,133,2000)
                        with (leaf/(stem+'-diff.log')).open('x') as log:
                            assert compare.compare_func(gold,trace,False,0xffffffff,False,20,log,sys_both=True)==0, (case,stem,'QEMU diff')
                assert stops['cycle'] == stops['cycle-func'], 'observation changed clocks'
                assert backing['cycle'] == backing['cycle-func'], 'observation changed AXI activity'
                rows = traces['cycle']
                # Cycle records omit segment fields; full functional comparison
                # above verifies CS, while this fixture keeps PC values unique.
                hits = [i for i,r in enumerate(rows) if int(r['pc'],0)==hot_pc]
                assert len(hits)==16, (case, name, 'hot instruction count', len(hits))
                pairs = [r for r in rows if int(r['pc'],0)==symbols['pair_v'] and r.get('pipe')=='V' and r.get('paired')]
                assert len(pairs)==1, (case,name,'missing actual UV pair')
                measures.append(dict(case=case,model=name,latency=latency,records=len(rows),clocks=stops['cycle'],
                    axi_fill_cycles=backing['cycle'][0],axi_backing_acks=backing['cycle'][2],
                    paired_v=len(pairs),hot_intervals=[rows[i]['cyc']-rows[i-1]['cyc'] for i in hits],
                    warm_loops=[rows[b]['cyc']-rows[a]['cyc'] for a,b in zip(hits[2:-1],hits[3:])]))
        save(leaf/'closed.json',dict(passed=True,measurements=measures,image_sha256=sha(image)))
        return measures

    result = dict(passed=False,errors=[],measurements=[],gameplay_ipc=None,standard_suite=False,all_children_reaped=False)
    started = time.monotonic()
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = {pool.submit(check,c):c for c in cases}
            for future in concurrent.futures.as_completed(futures):
                try:
                    result['measurements'].extend(future.result())
                except Exception as exc:
                    result['errors'].append(dict(case=futures[future],error=repr(exc)))
        assert len(result['measurements'])==len(cases)*4 and not result['errors']
        result['passed']=True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc)))
    finally:
        resource_after=resources()
        save(args.out/'resources-after.json',resource_after)
        reaped=set(resource_after['cgroup.procs'].split())==set(resource_before['cgroup.procs'].split())
        events=dict(line.split() for line in resource_after['memory.events'].splitlines())
        clean_resources=events['oom']==events['oom_kill']=='0' and resource_after['pids.events']==resource_before['pids.events']
        result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),all_children_reaped=reaped,
                      clean_resources=clean_resources,
                      seconds=time.monotonic()-started)
        result['passed'] &= result['pins_unchanged'] and reaped and clean_resources
        save(args.out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'},indent=2),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    sys.exit(main())
