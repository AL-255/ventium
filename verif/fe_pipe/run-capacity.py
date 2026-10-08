#!/usr/bin/env python3
"""Measure the data-translation working-set cliff on a prebuilt UV-fast core.

No RTL rebuild or mode downgrade; complete native exits and unmodified full
QEMU differentials are required. This measures microbenchmarks, not gameplay.
Two small jobs at a time so this can coexist with the single guarded synthesis.
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
import signal
import socket
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / 'verif/diff'))
import tracefmt
spec = importlib.util.spec_from_file_location('native_capacity', REPO / 'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = native
spec.loader.exec_module(native)


def digest(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tb', type=Path, required=True)
    parser.add_argument('--pages', type=int, nargs='+', default=[4, 7, 8, 9, 16, 32, 64])
    parser.add_argument('--no-cut-reference', action='store_true',
                        help='require a prebuilt no-FE model; UV-fast remains mandatory')
    args = parser.parse_args()
    if not args.pages or len(set(args.pages)) != len(args.pages) or any(n < 1 or n > 64 for n in args.pages):
        parser.error('unique page counts 1..64 required')
    tb = args.tb.resolve(strict=True)
    stamp = tb.parent / 'Vventium_top__verFiles.dat'
    commands = [line for line in stamp.read_text().splitlines() if line.startswith('C ')]
    assert len(commands) == 1
    defines = set(re.findall(r'\+define\+(\w+)', commands[0]))
    required = {'VEN_L1_AXI', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
                'VEN_SYS_FASTSTORE_FLAT', 'VEN_SEG_ENFORCE', 'VEN_PERF_PROFILE'}
    cut_flags = {'VEN_FE_PIPE', 'VEN_FE_DTLB_MULTI', 'VEN_FE_DTLB_PERM'}
    if args.no_cut_reference:
        assert not cut_flags & defines, 'reference must have no translation-cut flags'
    else:
        required |= cut_flags
    assert required <= defines and ' --assert ' in commands[0]
    assert not {'SYNTHESIS', 'VTM_NO_DPI', 'VEN_FE_MEM_CHAIN'} & defines
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert subprocess.check_output(['findmnt', '-T', str(scratch), '-no', 'FSTYPE'], text=True).strip() == 'ext4'
    assert shutil.disk_usage(scratch).free > 512 * 1024**2
    out = Path(tempfile.mkdtemp(prefix='ventium-fe-capacity.', dir=scratch))
    print(f'Evidence: {out}', flush=True)
    qemu = REPO / 'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    linker = REPO / 'verif/sys/tests/ppage/ppage.ld'
    pins = [Path(__file__), HERE / 'capacity.S', tb, stamp, qemu, linker,
            REPO / 'verif/qemu-trace/gen_trace.py', REPO / 'verif/diff/compare.py',
            REPO / 'verif/diff/tracefmt.py', REPO / 'verif/sys/run-native-system.py']
    before = {str(p): digest(p) for p in pins}
    (out / 'inputs.json').write_text(json.dumps(before, indent=2))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1')

    def run(argv, stem, *, expected=0, latency=0):
        (out / (stem+'.command.json')).write_text(json.dumps([str(a) for a in argv], indent=2))
        with (out / (stem+'.stdout')).open('xb') as stdout, (out / (stem+'.stderr')).open('xb') as stderr:
            p = subprocess.Popen(argv, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                                 stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                rc = p.wait(timeout=120)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGTERM)
                try:
                    p.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(p.pid, signal.SIGKILL)
                    p.wait()
                rc = 124
        (out / (stem+'.exit')).write_text(str(rc)+'\n')
        assert rc == expected, (stem, rc, expected)
        return rc

    def prepare(pages):
        stem = f'p{pages}'
        directory = out / stem
        directory.mkdir()
        obj, elf, image = (directory / ('fixture.'+suffix) for suffix in ('o', 'elf', 'bin'))
        run(['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic', '-fno-pie', '-Wall',
             f'-DPAGES={pages}', '-c', HERE / 'capacity.S', '-o', obj], stem+'-assemble')
        run(['gcc', '-m32', '-static', '-no-pie', '-nostdlib', '-Wl,-T,'+str(linker),
             '-Wl,--build-id=none', obj, '-o', elf], stem+'-link')
        run(['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image], stem+'-binary')
        assert image.stat().st_size == 65536
        run([qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64', '-bios', image,
             '-display', 'none', '-serial', 'none', '-monitor', 'none', '-no-reboot',
             '-no-shutdown', '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], stem+'-qemu', expected=133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        run([sys.executable, '-B', REPO / 'verif/qemu-trace/gen_trace.py', '--qemu', qemu,
             '--system', '--image', image, '--image-mode', 'bios', '--cpu', 'pentium',
             '--out', directory / 'golden.vtrace', '--max-insn', '10000', '--port', str(port)], stem+'-golden')
        symbols = {s[2]:int(s[0],16) for line in subprocess.check_output(['nm', '-n', elf], text=True).splitlines()
                   if len(s := line.split()) == 3}
        (directory/'symbols.json').write_text(json.dumps(symbols, indent=2))

    def check(job):
        pages, latency = job
        directory = out / f'p{pages}'
        symbols = json.loads((directory / 'symbols.json').read_text())
        traces = {}
        for mode in ('cycle-func', 'cycle'):
            stem = f'p{pages}-lat{latency}-{mode}'
            trace = out / (stem+'.vtrace')
            rc = run([tb, '--system', '--cosim', '--'+mode, '--l1-axi', '--image', directory / 'fixture.bin',
                      '--out', trace, '--max-insn', '10000', '--max-cycles', '4000000', '--quiesce', '200000'],
                     stem, expected=133, latency=latency)
            parsed = tracefmt.read_trace(str(trace))
            traces[mode] = parsed.records
            if mode == 'cycle-func':
                native.grade_native(parsed, (out/(stem+'.stdout')).read_text(),
                                    (out/(stem+'.stderr')).read_text(), rc, 133, 10000)
                run([sys.executable, '-B', REPO / 'verif/diff/compare.py', '--mode', 'func', '--all',
                     '--max-report', '8', directory / 'golden.vtrace', trace], stem+'-compare')
        cyc, arch = traces['cycle'], traces['cycle-func']
        assert [r['pc'] for r in cyc] == [r['pc'] for r in arch]
        hits = [i for i,r in enumerate(cyc) if int(r['pc'],16) == symbols['hot_loop']]
        assert len(hits) == 10
        pairs = 0
        for i in hits:
            a,b = cyc[i:i+2]
            if (a['pipe'] == 'U' and b['pipe'] == 'V' and b['paired'] and
                    a['cyc'] == b['cyc'] and int(b['pc'],16) == symbols['first_independent']):
                pairs += 1
        assert pairs >= 7, ('no sustained fast load/independent V pairs', pages, latency, pairs)
        windows = [cyc[b]['cyc']-cyc[a]['cyc'] for a,b in zip(hits[2:-1], hits[3:])]
        assert len(windows) == 7 and all(c > 0 for c in windows)
        row = dict(pages=pages, latency=latency, passed=True, qemu_full_state=True,
                   first_load_paired_v=pairs, warm_round_cycles=windows,
                   warm_cycles_per_load=sum(windows)/(len(windows)*pages),
                   cycle_mode=1, records=len(cyc), gameplay_ipc=None, standard_suite=False)
        (out / f'p{pages}-lat{latency}-result.json').write_text(json.dumps(row, indent=2))
        print(json.dumps(row), flush=True)
        return row

    result = dict(passed=False, definitions=sorted(defines), gameplay_ipc=None, standard_suite=False,
                  profile='no-cut-UV-fast-reference' if args.no_cut_reference else 'eight-entry-UV-fast-cut')
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(prepare, args.pages))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            result['cases'] = list(pool.map(check, [(n,l) for n in args.pages for l in (0,7)]))
        result['passed'] = True
    finally:
        result['inputs_unchanged'] = all(digest(p) == sha for p,sha in before.items())
        result['passed'] &= result['inputs_unchanged']
        (out / 'result.json').write_text(json.dumps(result, indent=2))
    assert result['passed']
    print('FE-CAPACITY-UV-CORE-OK; not standard-suite or gameplay acceptance')


if __name__ == '__main__':
    main()
