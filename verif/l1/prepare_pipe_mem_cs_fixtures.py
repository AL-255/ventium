"""Assemble/audit 12 cold-boot CS-extent images; does NOT run a core model."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SOURCE = HERE / 't_pipe_mem_cs_extent.S'
LINKER = REPO / 'verif/sys/tests/pfetchlim/pfetchlim.ld'
CASES = [(kind, length, over) for kind in (0, 1)
         for length in (2, 3, 6) for over in (0, 1)]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def expected(kind, length, over):
    if (kind, length, over) not in CASES:
        raise ValueError('invalid CS-extent fixture case')
    opcode = bytes([0x8b if kind == 0 else 0x89])
    operand = {2: b'\x03', 3: b'\x43\x04',
               6: b'\x83\x04\0\0\0'}[length]
    return dict(kind=kind, length=length, over=over, probe_pc=0x8030,
                cs_limit=0x8030+length-1-over,
                fault_pc=0x8030 if over else 0x8030+length,
                opcode=(opcode+operand).hex(),
                eax=0x5eedf00d if kind == 0 and not over else
                    (0xdeadcafe if kind == 0 else 0xcafebabe),
                memory=0xcafebabe if kind == 1 and not over else 0x5eedf00d,
                fault_vector=13, error_code=0, fault_cs=0x18,
                expected_guest_exit=133)


def audit_image(image, symbols, case):
    """Check linked bytes, not just preprocessor intent or fixture exit code."""
    want = expected(*case)
    assert len(image) == 65536
    for name, key in (('PROBE_PC', 'probe_pc'), ('CS_LIMIT', 'cs_limit'),
                      ('FAULT_PC', 'fault_pc')):
        assert symbols[name] == want[key], (name, symbols[name], want[key])
    assert symbols['probe_insn'] - symbols['probe_template'] == 0x30
    assert symbols['probe_after'] - symbols['probe_insn'] == want['length']
    start = symbols['probe_template'] - 0xf0000
    probe = symbols['probe_insn'] - 0xf0000
    assert 0 <= start < probe < 0xfff0
    assert image[start:start+32] == bytes.fromhex('89f689ff')*8
    # Local short jump from copied address 8020 to 8030: makes the probe U.
    assert image[start+32:start+34] == bytes.fromhex('eb0e')
    assert image[probe:probe+want['length']].hex() == want['opcode']
    # An unchecked fallthrough must reach guest FAIL, never success.
    after = probe+want['length']
    assert image[after:after+7] == b'\xea'+symbols['fail'].to_bytes(4, 'little')+b'\x08\0'
    assert symbols['probe_end'] == symbols['probe_after']+7
    reset = b'\xea'+symbols['_start16_off'].to_bytes(2, 'little')+b'\0\xf0'
    assert image[0xfff0:0xfff5] == reset
    # Bootstrap installs the byte-granular, zero-base limited descriptor.
    low = b'\x66\xc7\x06\x18\x05'+want['cs_limit'].to_bytes(4, 'little')
    high = bytes.fromhex('66c7061c05009a4000')
    assert image.count(low) == image.count(high) == 1
    return want


def build_case(root, case):
    kind, length, over = case
    leaf = root / f'k{kind}-n{length}-over{over}'
    leaf.mkdir()
    obj, elf, binary = [leaf / ('fixture.'+x) for x in ('o', 'elf', 'bin')]
    commands = [
        ['/usr/bin/gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic',
         '-fno-pie', '-Wall', '-Werror', f'-DKIND={kind}', f'-DLENGTH={length}',
         f'-DOVER={over}', '-c', SOURCE, '-o', obj],
        ['/usr/bin/gcc', '-m32', '-static', '-no-pie', '-nostdlib',
         '-Wl,-T,'+str(LINKER), '-Wl,--build-id=none', obj, '-o', elf],
        ['/usr/bin/objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to',
         '0x100000', elf, binary],
    ]
    for number, command in enumerate(commands):
        command = list(map(str, command))
        with (leaf / f'{number}.command.json').open('x') as f:
            json.dump(command, f)
        with (leaf / f'{number}.log').open('x') as f:
            subprocess.run(command, check=True, timeout=20, stdout=f,
                           stderr=subprocess.STDOUT)
    raw = subprocess.check_output(['/usr/bin/nm', '-n', elf], text=True, timeout=10)
    with (leaf / 'symbols.txt').open('x') as f:
        f.write(raw)
    symbols = {p[2]: int(p[0], 16) for line in raw.splitlines()
               if len(p := line.split()) == 3 and p[0] != 'U'}
    want = audit_image(binary.read_bytes(), symbols, case)
    result = dict(expected=want, symbols=symbols, image=str(binary),
                  image_sha256=sha(binary), elf_sha256=sha(elf),
                  layout_passed=True, executed=False)
    with (leaf / 'layout.json').open('x') as f:
        json.dump(result, f, indent=2)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    root = args.out.resolve()
    assert root.is_relative_to(scratch) and root != scratch
    assert os.statvfs(scratch).f_bavail * os.statvfs(scratch).f_frsize > 512*1024**2
    root.mkdir()  # Never overwrite an existing run.
    pins = {str(p): sha(p) for p in (Path(__file__), SOURCE, LINKER,
            Path('/usr/bin/gcc'), Path('/usr/bin/as'), Path('/usr/bin/ld'),
            Path('/usr/bin/objcopy'), Path('/usr/bin/nm'))}
    with (root / 'started.json').open('x') as f:
        json.dump(dict(pins=pins, invocation=os.environ.get('INVOCATION_ID'),
                       affinity=sorted(os.sched_getaffinity(0))), f, indent=2)
    start = time.monotonic()
    cases = [build_case(root, case) for case in CASES]
    assert all(sha(p) == h for p, h in pins.items())
    with (root / 'closed.json').open('x') as f:
        json.dump(dict(layout_passed=True, cases=cases, pins_unchanged=True,
                       seconds=time.monotonic()-start, core_executed=False,
                       hardware_acceptance=False, standard_suite=False,
                       gameplay_ipc=None), f, indent=2)
    print('PIPE-CS-FIXTURES-READY: 12 audited images; NOT an execution pass')


if __name__ == '__main__':
    main()
