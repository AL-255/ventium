"""Six cold guest images for reachable new/held fast-memory CS qualification.

Derive the checked boundary fixture without changing its source or receipts.
The CS limit is exactly PC+15: the last interior window before checked fetch.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

import prepare_pipe_mem_cs_fixtures as boundary

REPO = boundary.REPO
CASES = [(kind, length) for kind in (0, 1) for length in (2, 3, 6)]


def source():
    text = boundary.SOURCE.read_text()
    for old, new in (
        ('.set CS_LIMIT, PROBE_PC + LENGTH - 1 - OVER', '.set CS_LIMIT, PROBE_PC + 15'),
        ('    cmpl $1, %edi\n', '    cmpl $0, %edi\n'),
        ('    cmpl $FAULT_PC, %esi\n', '    cmpl $0, %esi\n'),
        ('    /* Unchecked execution must NOT return a success marker. */\n'
         '    .byte 0xea\n    .long fail\n',
         '    /* Legal interior access returns through the checked guest oracle. */\n'
         '    .byte 0xea\n    .long case_return\n'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    return text


def audit_image(image, symbols, case):
    kind, length = case
    assert case in CASES and len(image) == 65536
    want = boundary.expected(kind, length, 0)
    want.update(cs_limit=0x803f, fault_pc=0, faults=0)
    assert symbols['PROBE_PC'] == 0x8030 and symbols['CS_LIMIT'] == 0x803f
    start, probe = (symbols[n]-0xf0000 for n in ('probe_template', 'probe_insn'))
    assert probe-start == 0x30 and symbols['probe_after']-symbols['probe_insn'] == length
    assert image[start:start+32] == bytes.fromhex('89f689ff')*8
    assert image[start+32:start+34] == bytes.fromhex('eb0e')
    assert image[probe:probe+length].hex() == want['opcode']
    assert image[probe+length:probe+length+7] == b'\xea'+symbols['case_return'].to_bytes(4,'little')+b'\x08\0'
    assert symbols['probe_end'] == symbols['probe_after']+7
    assert image.count(bytes.fromhex('66c70618053f800000')) == 1
    assert image.count(bytes.fromhex('66c7061c05009a4000')) == 1
    assert image[0xfff0:0xfff5] == b'\xea'+symbols['_start16_off'].to_bytes(2,'little')+b'\0\xf0'
    return want


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert scratch.stat().st_dev != REPO.stat().st_dev
    root.mkdir()
    assembly = root/'interior.S'; assembly.write_text(source())
    pins = {str(p): boundary.sha(p) for p in (Path(__file__).resolve(),
        Path(boundary.__file__), boundary.SOURCE, boundary.LINKER, assembly,
        Path('/usr/bin/gcc'), Path('/usr/bin/as'), Path('/usr/bin/ld'),
        Path('/usr/bin/objcopy'), Path('/usr/bin/nm'))}
    with (root/'started.json').open('x') as f: json.dump(dict(pins=pins), f, indent=2)
    start = time.monotonic(); rows = []
    for kind, length in CASES:
        leaf = root/f'k{kind}-n{length}'; leaf.mkdir()
        obj, elf, image = [leaf/('fixture.'+s) for s in ('o','elf','bin')]
        commands = [
            ['/usr/bin/gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
             '-Wall','-Werror',f'-DKIND={kind}',f'-DLENGTH={length}','-DOVER=0','-c',assembly,'-o',obj],
            ['/usr/bin/gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(boundary.LINKER),
             '-Wl,--build-id=none',obj,'-o',elf],
            ['/usr/bin/objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image],
        ]
        for number, command in enumerate(commands):
            command = list(map(str, command))
            with (leaf/f'{number}.command.json').open('x') as f: json.dump(command, f)
            with (leaf/f'{number}.log').open('x') as f:
                subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, check=True, timeout=20)
        raw = subprocess.check_output(['/usr/bin/nm','-n',elf], text=True, timeout=10)
        (leaf/'symbols.txt').write_text(raw)
        symbols = {p[2]: int(p[0],16) for line in raw.splitlines()
                   if len(p:=line.split()) == 3 and p[0] != 'U'}
        want = audit_image(image.read_bytes(), symbols, (kind,length))
        rows.append(dict(expected=want, symbols=symbols, image=str(image),
                         image_sha256=boundary.sha(image), executed=False))
    assert all(boundary.sha(p) == h for p,h in pins.items())
    with (root/'closed.json').open('x') as f:
        json.dump(dict(layout_passed=True, pins_unchanged=True, cases=rows,
                       seconds=time.monotonic()-start, core_executed=False), f, indent=2)
    print('PIPE-CS-INTERIOR-READY: six audited images; NOT an execution pass')


if __name__ == '__main__': main()
