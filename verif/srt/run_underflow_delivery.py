#!/usr/bin/env python3
"""Cold protected-mode underflow delivery probes using existing UV-fast models.

No Verilator build, QEMU promotion, snapshot or source mutation. The old
underflow-bad model is a negative control, not an alternative acceptance mode.
FLD1 is tested even when VEN_X87_MF_STRICT is absent: that is a real failure,
not an expected-failure waiver. FWAIT/FNOP results are reported separately.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import traceback

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/qemu-trace/remainder_sequence'))
sys.path.insert(0, str(REPO/'verif/diff'))
import underflow_vectors as exact
import partial_underflow_vectors as partial
import tracefmt

BASE = REPO/'verif/sys/tests/px87stk/px87trap.S'
LINK = BASE.with_name('px87stk.ld')
BASE_SHA = 'ef98a4227a7dfde5a0e1db12bef2a669a39d2af3539ce3653c3869d850d0512d'
LINK_SHA = 'dcb880e2f08e8403c68c49ee7a053ca750fcaf3ddae52aa0014d250de310d9d5'
MODELS = {
    'bad': ('core-exceptions-r2', '2ac15c8ba4fd6fbfcfb2dccb0daa0bb41448e7756b6abd2b2e32b8a92684bc1e'),
    'underflow': ('core-underflow-r1', '77c0c895122a6d7c890924e4806af51d287cd64c5d2094aa9eaa8032079fab1d'),
    'branch': ('branch-address-core-r1', '6deb3e92ae302d2166c18d239711754c049f1f775f2518a2f5b576108eb8b16d'),
}


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def vectors():
    normal = (1, 1 << 63)
    result = []
    for op in (0, 1):
        for name, a, b in (
            ('normal', (1, (1 << 63)+1) if op == 0 else normal,
             normal if op == 0 else (1, (1 << 63)+1)),
            ('tiny-finite', (0, 3), (0x4000, 1 << 63)),
            ('tiny-infinity', (0x8000 if op else 0, 3), (0x7fff, 1 << 63)),
            ('partial', (4, (1 << 63)+2), (0, 3)),
        ):
            r = dict(name=name+str(op), op=op, a=a, b=b, cw=0x036f, sw=0x3000, tag=0)
            if name == 'partial':
                e = partial.expected(r)
                values, status = e['values'], e['status']
            elif name == 'tiny-infinity':
                values = {exact.encode(-3 if op else 3, wrapped=True)}
                status = 0xb092
            else:
                e = exact.expected(r)
                values, status = {e['value']}, e['status']
            result.append(r | dict(values=sorted(values), status=status & 0x80ff))
    return result


def source(r, waiter):
    assert waiter in ('fwait', 'fnop', 'fld1') and sha(BASE) == BASE_SHA
    s = BASE.read_text()
    arm = ['.macro ARM_PENDING_MF', '    fninit']
    for address, (exponent, mantissa) in ((0x2040, r['b']), (0x2050, r['a'])):
        arm += [f'    movl $0x{mantissa & 0xffffffff:08x}, 0x{address:x}',
                f'    movl $0x{mantissa >> 32:08x}, 0x{address+4:x}',
                f'    movw $0x{exponent:04x}, 0x{address+8:x}']
    arm += ['    fldt 0x2040', '    fldt 0x2050',
            '    fnclex /* remove load DE: arithmetic must raise its own status */',
            '    movw $0x036f, CWCELL', '    fldcw CWCELL',
            '    fprem1' if r['op'] else '    fprem', '.endm']
    s, count = re.subn(r'\.macro ARM_PENDING_MF\n.*?\.endm', '\n'.join(arm), s, flags=re.S)
    assert count == 1
    # DELAYED_MF keeps EXPECT_EIP setup BEFORE arithmetic. No observation or
    # inserted integer instruction can serialize the immediate waiting test.
    s, count = re.subn(r'^    fwait[^\n]*$', '' if waiter == 'fld1' else '    '+waiter,
                      s, flags=re.M)
    assert count == 2
    s = s.replace('andl    $0x009f, %eax', 'andl    $0x80ff, %eax')
    s = s.replace('cmpl    $0x0088, %eax', f'cmpl    $0x{r["status"]:04x}, %eax')
    check = ['.macro CHECK_REMAINDER', '    fstpt 0x2080']
    for exponent, mantissa in r['values']:
        check += [f'    cmpl $0x{mantissa & 0xffffffff:08x}, 0x2080', '    jne 990f',
                  f'    cmpl $0x{mantissa >> 32:08x}, 0x2084', '    jne 990f',
                  f'    cmpw $0x{exponent:04x}, 0x2088', '    je 991f', '990:']
    check += ['    movl $0xe1, %edi', '    jmp fail_exit', '991:',
              '    fstpt 0x2090',
              f'    CHKL 0x2090, 0x{r["b"][1] & 0xffffffff:08x}, 0xe2',
              f'    CHKL 0x2094, 0x{r["b"][1] >> 32:08x}, 0xe3',
              '    movzwl 0x2098, %eax', f'    cmpl $0x{r["b"][0]:04x}, %eax',
              '    je 992f', '    movl $0xe4, %edi', '    jmp fail_exit', '992:',
              '    CHKTOP 0, 0xe5', '.endm']
    s = '\n'.join(check)+'\n'+s
    for code in ('0x24', '0x34'):
        old = f'    CHKL    RDINT,     1,       {code}\n'
        assert s.count(old) == 1
        s = s.replace(old, old+'    CHECK_REMAINDER\n')
    return ('/* Generated underflow probe; inherited overflow comments below are historical. */\n'
            '.set DELAYED_MF, 1\n'+s)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--evidence', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root, out = a.evidence.resolve(strict=True), a.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.sched_getaffinity(0) == {12} and os.environ['INVOCATION_ID']
    assert shutil.disk_usage(scratch).free > 4.5 * 1024**3
    assert sha(BASE) == BASE_SHA and sha(LINK) == LINK_SHA
    pins = {str(p): sha(p) for p in (BASE, LINK, Path(__file__), Path(tracefmt.__file__),
            *sorted((REPO/'verif/qemu-trace/remainder_sequence').glob('*.py')))}
    definitions, binaries = {}, {}
    for label, (directory, digest) in MODELS.items():
        folder = root/directory
        started = json.loads((folder/'build-started.json').read_text())
        built = json.loads((folder/'build-closed.json').read_text())
        binary = folder/'obj/tb_ventium'
        assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged']
        assert sha(binary) == built['binary_sha256'] == digest
        assert all(sha(p) == h for p, h in started['pins'].items())
        definitions[label] = started['definitions']
        assert {'VEN_FP_SHARED_DIRECT', 'VEN_FP_ASYNC', 'VEN_L1_AXI', 'VEN_FE_PIPE',
                'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTSTORE_FLAT',
                'VEN_AO486_SINGLE_FILL'} <= set(definitions[label])
        pins.update(started['pins'])
        for p in (binary, folder/'build-started.json', folder/'build-closed.json'):
            pins[str(p)] = sha(p)
        binaries[label] = binary
    out.mkdir()

    def save(p, value):
        with p.open('x') as f:
            json.dump(value, f, indent=2)

    save(out/'started.json', dict(pins=pins, definitions=definitions, vectors=vectors(),
         invocation=os.environ['INVOCATION_ID'], cpu=12, cycle_mode=1,
         debugger_step=False, snapshots=False, acceptance_requires_all_waiters=True))
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VEN_', 'VTM_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1')

    def native(cmd, log, extra=None, model=None):
        begin = time.monotonic()
        seen = None
        with log.open('x') as stream:
            p = subprocess.Popen(list(map(str, cmd)), env=env | (extra or {}),
                                 stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                while p.poll() is None:
                    if time.monotonic()-begin > 60:
                        raise subprocess.TimeoutExpired(cmd, 60)
                    if model and seen is None:
                        try:
                            if Path('/proc', str(p.pid), 'exe').resolve(strict=True) == model:
                                assert os.sched_getaffinity(p.pid) == {12}
                                args = Path('/proc', str(p.pid), 'cmdline').read_bytes().split(b'\0')[:-1]
                                if args:
                                    assert args == [str(x).encode() for x in cmd]
                                    seen = dict(pid=p.pid, argv=[x.decode() for x in args], cpu=12,
                                        cgroup=Path('/proc', str(p.pid), 'cgroup').read_text(),
                                        stat=Path('/proc', str(p.pid), 'stat').read_text())
                        except (FileNotFoundError, ProcessLookupError):
                            pass
                    time.sleep(.002)
                code = p.wait()
            except BaseException:
                if p.poll() is None:
                    os.killpg(p.pid, signal.SIGTERM)
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(p.pid, signal.SIGKILL)
                    p.wait()
                raise
        receipt = dict(command=list(map(str, cmd)), native_exit=code, actual_wait=True,
                       observed=seen, seconds=time.monotonic()-begin, log_sha256=sha(log))
        save(log.with_suffix('.closed.json'), receipt)
        assert (seen is not None if model else code == 0), receipt
        return receipt

    begin, rows, errors = time.monotonic(), [], []
    try:
        for vector in vectors():
            for waiter in ('fwait', 'fnop', 'fld1'):
                folder = out/(vector['name']+'-'+waiter)
                folder.mkdir()
                asm = folder/'test.S'
                # Generated fixture, not a repository source edit.
                asm.write_text(source(vector, waiter))
                native(['as', '--32', asm, '-o', folder/'test.o'], folder/'assemble.log')
                native(['ld', '-m', 'elf_i386', '-T', LINK, folder/'test.o', '-o', folder/'test.elf'], folder/'link.log')
                native(['objcopy', '-O', 'binary', folder/'test.elf', folder/'test.bin'], folder/'binary.log')
                assert (folder/'test.bin').stat().st_size <= 65536
                with (folder/'test.bin').open('r+b') as f:
                    f.truncate(65536)
                for latency in (0, 7, 31):
                    for label, model in binaries.items():
                        prefix = f'{label}-lat{latency}'
                        log, trace = folder/(prefix+'.log'), folder/(prefix+'.vtrace')
                        receipt = native([model, '--system', '--cosim', '--cycle-func', '--l1-axi',
                            '--image', folder/'test.bin', '--out', trace, '--max-insn', '10000',
                            '--max-cycles', '2000000', '--quiesce', '4096', '+ven_faultlog'],
                            log, dict(AXI_RLAT=str(latency), AXI_WLAT=str(latency)), model)
                        text = log.read_text()
                        records = tracefmt.read_trace(str(trace)).records
                        assert records and not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED', text)
                        faults = re.findall(r'^\[FAULT\] vec=(\d+)\b', text, re.M)
                        v = int(re.search(r'pairedV=(\d+)', text)[1])
                        clocks = int(re.search(r'^  clocks\s+(\d+)', text, re.M)[1])
                        backing = int(re.search(r'^\[L1DPERF\] fill cycles=\d+ backing-wait=\d+ backing-ack=(\d+)$', text, re.M)[1])
                        assert v > 0 and backing > 0
                        final = {k: int(records[-1][k], 0) for k in ('eax', 'ebx', 'ecx', 'esi', 'edi')}
                        passed = (receipt['native_exit'] == 133 and final == dict(eax=0x42, ebx=3, ecx=2, esi=4, edi=0x42)
                                  and faults == ['7', '7', '16', '7', '16'])
                        rows.append(dict(vector=vector['name'], waiter=waiter, latency=latency,
                            model=label, passed=passed, final=final, faults=faults, v=v, clocks=clocks,
                            backing_acks=backing, records=len(records), native=receipt,
                            image_sha256=sha(folder/'test.bin'), trace_sha256=sha(trace)))
        # The address-shape experiment must not alter these architectural tests.
        for i in range(0, len(rows), 3):
            arow, brow = rows[i+1], rows[i+2]
            for key in ('passed', 'final', 'faults', 'v', 'clocks', 'backing_acks', 'records', 'trace_sha256'):
                assert arow[key] == brow[key], (key, arow, brow)
    except Exception as error:
        errors.append(dict(error=repr(error), traceback=traceback.format_exc()))
    stable = all(sha(p) == h for p, h in pins.items())
    summary = {label: {waiter: dict(passed=sum(r['passed'] for r in rows if r['model'] == label and r['waiter'] == waiter),
                    total=sum(r['model'] == label and r['waiter'] == waiter for r in rows))
                for waiter in ('fwait', 'fnop', 'fld1')} for label in MODELS}
    complete = not errors and stable and len(rows) == 216
    result = dict(completed=complete, candidate_passed=complete and all(r['passed'] for r in rows if r['model'] == 'branch'),
        summary=summary, rows=rows, errors=errors, pins_unchanged=stable, seconds=time.monotonic()-begin,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None, qemu_differential=False)
    save(out/'closed.json', result)
    print(json.dumps({k: v for k, v in result.items() if k != 'rows'}, indent=2), flush=True)
    return int(not result['candidate_passed'])


if __name__ == '__main__':
    raise SystemExit(main())
