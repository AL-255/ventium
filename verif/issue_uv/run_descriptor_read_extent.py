#!/usr/bin/env python3
"""Reproduce an excess LGDT/LIDT page read using ordinary guest instructions.

Diagnostic, not a passing differential gate: a completed investigation can
confirm that the existing models disagree with QEMU. No RTL build, snapshots,
guest stepping, altered architectural traces, or golden masks are used.
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
import traceback

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'verif/diff'))
import compare
import tracefmt

SOURCE_SHA = '24b52b3249def16ecf9f10921b4dc353b7a76ee123545fde36ddbeb9b59e9757'
MODELS = {
    'bus': ('ventium-bus-cancel-payload.Fzx7hUyD/core-r1/obj/tb_ventium',
            'f2797f8c17cb6c7d8668432ae69dd42d427d25a3e3d3b3cd1452de8d6582b4bf'),
    'exact': ('ventium-fragment-read-payload.etYN56fg/exact-core-r1/obj/tb_ventium',
              'e4ed9c0c01f53b96fc7da451695feea84b9eabf0891589107711300f042f65c8'),
}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def fixture(source, address, op, cd):
    assert hashlib.sha256(source.encode()).hexdigest() == SOURCE_SHA
    assert address in (0x2ff8, 0x2ff9, 0x2ffa) and op in ('lgdt', 'lidt')
    anchor = '    /* ================= case A: frag2 abort + stale-frag1 poison ============ */'
    prefix = source[source.index('    .code16'):source.index(anchor)]
    before = ('    movw    $0x002F, 0x00002FFE         /* case A limit (handler poisons to 0x47) */\n'
              '    movl    $0x00400000, 0x00600000     /* case A base  (phys of NP page 3) */')
    assert prefix.count(before) == 1
    prefix = prefix.replace(before,
        f'    movw $0x002F, 0x{address:08x}\n    movl $0x00400000, 0x{address+2:08x}')
    # The original handler maps page 3 if incorrectly touched, then retries.
    # Its poison at 0x2ffe makes some erroneous restarts additionally visible
    # in the saved descriptor. Nothing changes the DUT or its memory externally.
    body = f'''
    movl %cr0, %eax
    andl $0x9fffffff, %eax
    orl $0x{(0x40000000 if cd else 0):08x}, %eax
    movl %eax, %cr0
    {op} 0x{address:08x}
    {'sgdt' if op == 'lgdt' else 'sidt'} 0x00002080
    movzwl 0x00002080, %ebx
    movl 0x00002082, %ebp
    movl 0x00002028, %ecx
    movl %cr2, %esi
    movl $0x42, %eax
    movw $0xf4, %dx
    outb %al, %dx
hang:
    hlt
    jmp hang
'''
    return ('/* Generated descriptor extent diagnostic; pxfrag setup/handlers retained. */\n'
            + prefix + body + source[source.index('/* #PF handler:'):])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4 * 1024**3
    source = REPO / 'verif/sys/tests/pxfrag/pxfrag.S'
    linker = source.with_suffix('.ld')
    qemu = REPO / 'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    native_path = REPO / 'verif/sys/run-native-system.py'
    spec = importlib.util.spec_from_file_location('descriptor_native', native_path)
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    pins = {str(p): sha(p) for p in (source, linker, qemu, native_path, Path(__file__),
            Path(compare.__file__), Path(tracefmt.__file__), REPO/'verif/qemu-trace/gen_trace.py')}
    for relative, digest in MODELS.values():
        model = scratch / relative
        assert sha(model) == digest
        stamp = model.parent / 'Vventium_top__verFiles.dat'
        command = next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
        definitions = set(re.findall(r'\+define\+(\w+)', command))
        assert {'VEN_FE_PIPE', 'VEN_L1_AXI', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
                'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT', 'VEN_SEG_ENFORCE'} <= definitions
        assert '--assert' in command and not {'SYNTHESIS', 'VTM_NO_DPI'} & definitions
        pins[str(model)] = digest
        pins[str(stamp)] = sha(stamp)
    out.mkdir()
    save(out/'started.json', dict(pins=pins, inv=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), diagnostic=True, gameplay_ipc=None))
    start = time.monotonic()
    golden_lock = threading.Lock()

    def run(leaf, label, argv, expected, latency=0):
        argv = ['timeout', '--signal=TERM', '--kill-after=2s', '30s', *map(str, argv)]
        save(leaf/(label+'.command.json'), argv)
        with (leaf/(label+'.stdout')).open('x') as stdout, (leaf/(label+'.stderr')).open('x') as stderr:
            process = subprocess.run(argv, stdout=stdout, stderr=stderr,
                env={**os.environ, 'AXI_RLAT': str(latency), 'AXI_WLAT': str(latency)})
        save(leaf/(label+'.exit.json'), dict(native_exit=process.returncode, actual_wait=True,
            stdout_sha256=sha(leaf/(label+'.stdout')), stderr_sha256=sha(leaf/(label+'.stderr'))))
        assert process.returncode == expected, (label, process.returncode, expected)
        return (leaf/(label+'.stdout')).read_text(), (leaf/(label+'.stderr')).read_text()

    def check(address, op, cd):
        name = f'{op}-{address:x}-cd{cd}'
        leaf = out/name
        leaf.mkdir()
        row = dict(case=name, measurements=[], errors=[], investigation_completed=False)
        try:
            assembly, obj, elf, image = [leaf/('fixture.'+s) for s in ('S', 'o', 'elf', 'bin')]
            assembly.write_text(fixture(source.read_text(), address, op, cd))
            run(leaf, 'assemble', ['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic',
                '-fno-pie', '-Wall', '-c', assembly, '-o', obj], 0)
            run(leaf, 'link', ['ld', '-m', 'elf_i386', '-T', linker, obj, '-o', elf], 0)
            run(leaf, 'binary', ['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to',
                '0x100000', elf, image], 0)
            assert image.stat().st_size == 65536
            row['image_sha256'] = sha(image)
            run(leaf, 'qemu-free', [qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64',
                '-bios', image, '-display', 'none', '-serial', 'stdio', '-monitor', 'none',
                '-no-reboot', '-no-shutdown', '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], 133)
            with golden_lock:
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0))
                    port = sock.getsockname()[1]
                run(leaf, 'golden', [sys.executable, '-B', REPO/'verif/qemu-trace/gen_trace.py',
                    '--qemu', qemu, '--system', '--cpu', 'pentium', '--image', image,
                    '--image-mode', 'bios', '--out', leaf/'golden.vtrace',
                    '--max-insn', '3000', '--port', port], 0)
            golden = tracefmt.read_trace(str(leaf/'golden.vtrace'))
            def witness(trace):
                return {key: tracefmt.parse_hex(trace.records[-1][key]) for key in ('ecx', 'ebx', 'ebp', 'esi')}
            expected = witness(golden)
            assert expected == dict(ecx=0, ebx=0x2f, ebp=0x400000, esi=0), expected
            row['qemu_witness'] = expected
            for label, (relative, _) in MODELS.items():
                for latency in (0, 7):
                    prefix = f'{label}-lat{latency}'
                    trace = leaf/(prefix+'.vtrace')
                    stdout, stderr = run(leaf, prefix, [scratch/relative, '--system', '--cosim',
                        '--l1-axi', '--cycle-func', '--image', image, '--out', trace,
                        '--max-insn', '3000', '--max-cycles', '3000000', '--quiesce', '8000',
                        '+ven_faultlog', '+ven_xpagelog'], 133, latency)
                    got = tracefmt.read_trace(str(trace))
                    stats = native.grade_native(got, stdout, stderr, 133, 133, 3000)
                    with (leaf/(prefix+'-diff.log')).open('x') as log:
                        diff = compare.compare_func(golden, got, False, 0xffffffff, False, 20, log, sys_both=True)
                    observed = witness(got)
                    row['measurements'].append(dict(model=label, latency=latency,
                        witness=observed, differential_exit=diff, **stats))
                    if address == 0x2ff8:
                        assert diff == 0 and observed == expected, (name, prefix, observed)
                    else:
                        assert diff != 0 and observed['ecx'] == 1 and observed['esi'] == 0x3000, (name, prefix, observed)
            row['investigation_completed'] = True
        except Exception as error:
            row['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
        save(leaf/'closed.json', row)
        return row

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(check, address, op, cd) for op in ('lgdt', 'lidt')
                   for address in (0x2ff8, 0x2ff9, 0x2ffa) for cd in (0, 1)]
        rows = [future.result() for future in futures]
    stable = all(sha(p) == h for p, h in pins.items())
    result = dict(investigation_completed=stable and all(r['investigation_completed'] for r in rows),
        rows=rows, pins=pins, pins_unchanged=stable, seconds=time.monotonic()-start,
        qualification='DIAGNOSTIC_ONLY', candidate_fixed=False, gameplay_ipc=None, standard_suite=False)
    save(out/'closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k != 'pins'}), flush=True)
    return 0 if result['investigation_completed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
