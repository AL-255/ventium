"""Cold failure witnesses for FENI/FDISI/FSETPM and unchanged FNOP controls.

Expected missing-instruction results, NOT a differential or repair pass.
QEMU native self-checks qualify fixtures; no golden, mask or RTL edits.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('out', 'model'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    root, model = args.out.resolve(), args.model.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.sched_getaffinity(0) == {14,15} and os.environ.get('INVOCATION_ID')
    assert shutil.disk_usage(scratch).free > 4*1024**3
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    pins = {str(p):sha(p) for p in (Path(__file__), HERE/'probe.S', HERE/'probe.ld', qemu, model)}
    assert sha(qemu) == 'b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd'
    assert sha(model) == 'fddb1fd3f7b677c44ddcc320808a9b756e45adc38718ff4d08b1dedb94d6b52b'
    root.mkdir()

    def save(name, value):
        with (root/name).open('x') as stream:
            json.dump(value, stream, indent=2)

    env = {k:v for k,v in os.environ.items()
           if not k.startswith(('VEN_', 'VENTIUM_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(AXI_RLAT='7', AXI_WLAT='7', PYTHONDONTWRITEBYTECODE='1')

    def run(name, command, seconds=10):
        actual = ['taskset', '-c', '14,15', 'timeout', '--signal=TERM', '--kill-after=2s',
                  str(seconds)+'s', *map(str, command)]
        save(name+'.command.json', actual)
        with (root/(name+'.log')).open('x') as stream:
            return subprocess.run(actual, env=env, stdout=stream, stderr=subprocess.STDOUT).returncode

    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=[14,15], diagnostic_only=True, expected_missing=True))
    begin = time.monotonic()
    result = dict(passed=False, rows=[], errors=[], repaired_rtl=False, differential_gate=False,
                  standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    try:
        # One FNOP control per CR0/prefix setting (not repeated per obsolete opcode).
        cases = [(op, bits, prefix, 0) for op,bits,prefix in
                 itertools.product((0xe0,0xe1,0xe4), (0,4,8,12), (0,1))]
        cases += [(0xd0,bits,prefix,1) for bits,prefix in itertools.product((0,4,8,12),(0,1))]
        for op,bits,prefix,control in cases:
            name = f'o{op:x}-b{bits:x}-p{prefix}-c{control}'
            defines = dict(OPCODE=op, BITS=bits, PREFIX=prefix, CONTROL=control)
            obj, elf, binary = [root/(name+s) for s in ('.o','.elf','.bin')]
            assert run(name+'-as', ['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
                *[f'-D{k}={v}' for k,v in defines.items()],'-c',HERE/'probe.S','-o',obj]) == 0
            assert run(name+'-ld', ['ld','-m','elf_i386','-T',HERE/'probe.ld','--build-id=none',obj,'-o',elf]) == 0
            assert run(name+'-bin', ['objcopy','-O','binary',elf,binary]) == 0
            assert binary.stat().st_size == 65536
            q = run(name+'-qemu', [qemu,'-display','none','-monitor','none','-serial','none','-no-reboot',
                '-machine','pc','-cpu','pentium','-m','32','-device',
                'isa-debug-exit,iobase=0xf4,iosize=0x04','-bios',binary],5)
            r = run(name+'-rtl', [model,'--system','--cosim','--cycle-func','--l1-axi','--image',binary,
                '--out',root/(name+'.vtrace'),'--max-insn','2000','--max-cycles','1000000',
                '--quiesce','4096','+ven_faultlog','+ven_seglog'])
            # The existing unknown-op path already prioritizes x87 #NM when
            # EM/TS is set. Only usable-FPU obsolete opcodes expose missing decode.
            expected = 133 if control or bits else 135
            result['rows'].append(dict(case=defines, qemu_exit=q, rtl_exit=r,
                expected_rtl=expected, image_sha256=sha(binary)))
            assert q == 133, (name,'reference fixture failed',q)
            assert r == expected, (name,'missing-instruction witness',r)
            assert 'isa-debug-exit' in (root/(name+'-rtl.log')).read_text()
        result['passed'] = len(result['rows']) == 32
    except Exception as error:
        result['errors'].append(repr(error))
    result.update(seconds=time.monotonic()-begin, pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    result['artifacts'] = {str(p):sha(p) for p in root.iterdir() if p.is_file()}
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','artifacts')},indent=2),flush=True)
    print('cases',len(result['rows']),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
