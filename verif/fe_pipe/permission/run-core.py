#!/usr/bin/env python3
"""Two UV-fast permission/stack regressions on a caller-supplied native model.

No rebuild, mode fallback, guest snapshot or standard-suite acceptance.
All generated artifacts stay in a new external scratch directory.
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
REPO = HERE.parents[2]
SCRATCH = Path('/home/yukidama/external/tmp')
sys.path.insert(0, str(REPO / 'verif/diff'))
import tracefmt
spec = importlib.util.spec_from_file_location('native_system', REPO / 'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = native
spec.loader.exec_module(native)


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tb', required=True, type=Path)
    args = parser.parse_args()
    tb = args.tb.resolve(strict=True)
    stamp = tb.parent / 'Vventium_top__verFiles.dat'
    command_line = stamp.read_text().splitlines()[1]
    definitions = set(re.findall(r'\+define\+(\w+)', command_line))
    required = {'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
                'VEN_SYS_FASTSTORE_FLAT', 'VEN_SEG_ENFORCE', 'VEN_L1_AXI', 'VEN_PERF_PROFILE'}
    assert required <= definitions, ('missing build definitions', sorted(required - definitions))
    assert ' --assert ' in command_line, 'assertions must be enabled'
    assert subprocess.check_output(['findmnt', '-T', str(SCRATCH), '-no', 'FSTYPE'], text=True).strip() == 'ext4'
    assert shutil.disk_usage(SCRATCH).free > 128 * 1024**2
    out = Path(tempfile.mkdtemp(prefix='ventium-fe-permission-core.', dir=SCRATCH))
    print(f'UV-fast permission evidence: {out}', flush=True)
    qemu = REPO / 'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    cases = {
        'warm_ro': ('pfault', 'warm-ro.patch', ['-DFASTSTORE_PROBE', '-DPERM_WARM_PROBE'], 2000),
        'stack': ('pfaststack', 'valid-handler-fs.patch', [], 1000),
    }
    linker = REPO / 'verif/sys/tests/pfault/pfault.ld'
    pins = [Path(__file__), tb, stamp, qemu, linker,
            REPO / 'verif/qemu-trace/gen_trace.py', REPO / 'verif/diff/compare.py',
            REPO / 'verif/diff/tracefmt.py', REPO / 'verif/sys/run-native-system.py']
    for base, patch, _, _ in cases.values():
        pins += [REPO / f'verif/sys/tests/{base}/{base}.S', HERE / patch]
    before = {str(p): digest(p) for p in pins}
    (out / 'inputs.json').write_text(json.dumps(before, indent=2))
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VEN_', 'TB_', 'AXI_'))}
    env.update(TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1')

    def run(argv, stem, *, expected=0, latency=0, cwd=None):
        (out / (stem + '.command.json')).write_text(json.dumps([str(x) for x in argv], indent=2))
        with (out / (stem + '.stdout')).open('xb') as stdout, (out / (stem + '.stderr')).open('xb') as stderr:
            proc = subprocess.Popen(argv, stdout=stdout, stderr=stderr, cwd=cwd,
                                    env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)), start_new_session=True)
            try:
                rc = proc.wait(timeout=120)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                rc = 124
        (out / (stem + '.exit')).write_text(str(rc) + '\n')
        assert rc == expected, (stem, rc, expected)
        return rc

    def prepare(name):
        base, patch, defs, limit = cases[name]
        directory = out / name
        directory.mkdir()
        shutil.copyfile(REPO / f'verif/sys/tests/{base}/{base}.S', directory / 'fixture.S')
        run(['patch', '--batch', '--fuzz=0', '-p1', '-i', HERE / patch], name + '-patch', cwd=directory)
        run(['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic', '-fno-pie', '-Wall', *defs,
             '-c', directory / 'fixture.S', '-o', directory / 'fixture.o'], name + '-assemble')
        run(['gcc', '-m32', '-static', '-no-pie', '-nostdlib', '-Wl,-T,' + str(linker), '-Wl,--build-id=none',
             directory / 'fixture.o', '-o', directory / 'fixture.elf'], name + '-link')
        image = directory / 'fixture.bin'
        run(['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', directory / 'fixture.elf', image], name + '-binary')
        assert image.stat().st_size == 65536
        run([qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64', '-bios', image, '-display', 'none',
             '-serial', 'none', '-monitor', 'none', '-no-reboot', '-no-shutdown',
             '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], name + '-qemu', expected=133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        run([sys.executable, '-B', REPO / 'verif/qemu-trace/gen_trace.py', '--qemu', qemu, '--system',
             '--image', image, '--image-mode', 'bios', '--cpu', 'pentium', '--out', directory / 'golden.vtrace',
             '--max-insn', str(limit), '--port', str(port)], name + '-golden')
        return name

    def check(job):
        name, latency = job
        directory = out / name
        limit = cases[name][3]
        records = {}
        for mode in ('cycle-func', 'cycle'):
            stem = f'{name}-lat{latency}-{mode}'
            trace = out / (stem + '.vtrace')
            rc = run([tb, '--system', '--cosim', '--' + mode, '--l1-axi', '--image', directory / 'fixture.bin',
                      '--out', trace, '--max-insn', str(limit), '--max-cycles', '4000000', '--quiesce', '200000',
                      '+ven_faultlog'], stem, expected=133, latency=latency)
            parsed = tracefmt.read_trace(str(trace))
            log = (out / (stem + '.stdout')).read_text()
            records[mode] = parsed.records
            if mode == 'cycle-func':
                native.grade_native(parsed, log, (out / (stem + '.stderr')).read_text(), rc, 133, limit)
                run([sys.executable, '-B', REPO / 'verif/diff/compare.py', '--mode', 'func', '--all',
                     directory / 'golden.vtrace', trace], stem + '-compare')
            if name == 'stack':
                for kind, minimum in [('FAST_READ', 3), ('FAST_WRITE', 1)]:
                    match = re.search(r'mem-producer site=' + kind + r' events=(\d+)', log)
                    assert match and int(match[1]) >= minimum, ('fast stack path not exercised', kind)
        assert [r['pc'] for r in records['cycle']] == [r['pc'] for r in records['cycle-func']]
        paired = sum(r.get('pipe') == 'V' and r.get('paired', False) for r in records['cycle'])
        assert paired > 0, 'U-only cannot pass this gate'
        hot_pairs = None
        if name == 'warm_ro':
            symbols = {s[2]: int(s[0], 16) for line in subprocess.check_output(
                ['nm', '-n', str(directory / 'fixture.elf')], text=True).splitlines() if len(s := line.split()) == 3}
            u, v = symbols['perm_hot_read_u'], symbols['perm_hot_read_v']
            hits = [i for i, r in enumerate(records['cycle']) if int(r['pc'], 16) == u]
            assert len(hits) == 8
            for i in hits:
                a, b = records['cycle'][i:i+2]
                assert a['pipe'] == 'U' and b['pipe'] == 'V' and b['paired']
                assert a['cyc'] == b['cyc'] and int(b['pc'], 16) == v
            hot_pairs = len(hits)
        row = dict(name=name, latency=latency, cycle_mode=1, records=len(records['cycle']),
                   paired_v=paired, hot_read_add_pairs=hot_pairs, full_qemu_diff=True, passed=True)
        print(json.dumps(row), flush=True)
        return row

    result = dict(passed=False, gameplay_ipc=None, standard_suite=False, definitions=sorted(definitions))
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(prepare, cases))
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            result['cases'] = list(pool.map(check, [(n, l) for n in cases for l in (0, 7)]))
        result['passed'] = True
    finally:
        result['inputs_unchanged'] = all(digest(p) == sha for p, sha in before.items())
        result['passed'] &= result['inputs_unchanged']
        (out / 'result.json').write_text(json.dumps(result, indent=2))
    assert result['passed']
    print('FE-PERM-UV-CORE-OK; not standard-suite or hardware acceptance')


if __name__ == '__main__':
    main()
