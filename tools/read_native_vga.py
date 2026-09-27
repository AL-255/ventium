#!/usr/bin/env python3
"""Read-only VGA extraction from the pinned flat Vsystem V3 native snapshot.

No deserialization into a simulator, clocks, state migration or guest writes.
Validate the generated serializer grammar, every field dimension, both layout
checksums, repeated context bytes and complete file extent before extracting.
Unknown formats fail closed. Output files are diagnostic copies, not snapshots.
"""
import argparse
import hashlib
import json
import mmap
from pathlib import Path
import re
import struct

from checkpoint_bundle import verify_bundle


def need(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def datatype(text):
    text = re.sub(r'/\*.*?\*/', '', text).strip()
    scalars = dict(CData=1, SData=2, IData=4, QData=8, bool=1,
                   uint8_t=1, uint16_t=2, uint32_t=4, uint64_t=8, double=8)
    if text in scalars:
        return scalars[text], []
    wide = re.fullmatch(r'VlWide<(\d+)>', text)
    if wide:
        need(int(wide[1]) > 0, 'empty wide datatype')
        return 4, [int(wide[1])]
    array = re.fullmatch(r'VlUnpacked<(.+),\s*(\d+)>', text)
    need(array is not None, 'unsupported generated datatype: '+text)
    need(int(array[2]) > 0, 'empty array datatype')
    size, dims = datatype(array[1])
    return size, [int(array[2]), *dims]


def declarations(header):
    body = header.split('// DESIGN SPECIFIC STATE', 1)[1].split('// INTERNAL VARIABLES', 1)[0]
    fields = {}
    for raw in body.splitlines():
        line = raw.strip()
        if not line or line.startswith('//') or line in ('struct {', '};'):
            continue
        port = re.fullmatch(r'VL_(?:IN|OUT|INOUT)(8|16|64|W)?\((\w+),([^;]+)\);', line)
        if port:
            suffix, name, args = port.groups()
            if suffix == 'W':
                value = (4, [int(args.split(',')[-1])])
            else:
                value = ({None: 4, '8': 1, '16': 2, '64': 8}[suffix], [])
        else:
            match = re.fullmatch(r'(.+?)\s+(\w+);', line)
            need(match is not None, 'unknown declaration: '+line)
            if match[1].startswith('VlNBACommitQueue<'):
                continue
            name, value = match[2], datatype(match[1])
        need(name not in fields, 'duplicate declaration')
        fields[name] = value
    return fields


def serializer_layout(source, fields, cls='Vsystem___024root'):
    body = source.split(f'void {cls}::__Vserialize(VerilatedSerialize& os) {{', 1)[1].split(
        f'void {cls}::__Vdeserialize', 1)[0].strip()
    lines = [s.strip() for s in re.sub(r'//[^\n]*', '', body).splitlines() if s.strip()]
    checksum = re.fullmatch(r'uint64_t __Vcheckval = (0x[0-9a-f]+)ULL;', lines.pop(0))
    need(checksum is not None, 'missing checksum declaration')
    need(lines.pop(0) == 'os << __Vcheckval;' and lines.pop(0) == 'os << vlSymsp->_vm_contextp__;',
         'unknown serializer prefix')
    need(lines.pop() == '}', 'missing serializer end')
    loops, output, offset = [], {}, 0
    loop_emits = []
    for line in lines:
        loop = re.fullmatch(r'for \(int (__Vi\d+) = 0; \1 < (\d+); \+\+\1\) \{', line)
        if loop:
            need(loop[1] not in [n for n, _ in loops], 'duplicate loop variable')
            need(int(loop[2]) > 0, 'empty serializer loop')
            loops.append((loop[1], int(loop[2])))
            loop_emits.append(0)
        elif line == '}':
            need(bool(loops), 'unbalanced serializer loop')
            need(loop_emits.pop() == 1, 'interleaved or empty serializer loop')
            loops.pop()
        else:
            emit = re.fullmatch(r'os\s*<<\s*(\w+)((?:\[__Vi\d+\])*);', line)
            need(emit is not None and emit[1] in fields, 'unknown serializer operation: '+line)
            name, indices = emit[1], re.findall(r'\[(__Vi\d+)\]', emit[2])
            size, dims = fields[name]
            need(indices == [n for n, _ in loops] and dims == [n for _, n in loops],
                 'serializer dimensions differ: '+name)
            need(name not in output, 'repeated serializer field: '+name)
            loop_emits = [count + 1 for count in loop_emits]
            for dim in dims:
                size *= dim
            output[name] = dict(offset=offset, size=size, element_bytes=fields[name][0], dimensions=dims)
            offset += size
    need(not loops, 'unclosed serializer loop')
    return int(checksum[1], 16), output, offset


def snapshot_payload(data, checksum, payload_size, package_checksum):
    need(data[:16] == b'verilatorsave02\n', 'wrong native header')
    pos = 16
    def take(fmt):
        nonlocal pos
        value = struct.unpack_from(fmt, data, pos)
        pos += struct.calcsize(fmt)
        return value
    magic, = take('<Q')
    need(magic == 0x3350414e534e4556, 'not VENSNAP3')
    config = take('<9I')
    need(config[:8] == (45000000, 45000000, 90000000, 32, 2, 2, 4, 1), 'unqualified host ABI config')
    need(0 < config[8] < 65536, 'invalid ATA payload extent')
    spi = take('<3I')
    read_edge, = take('<I')
    need(read_edge in (0, 1), 'invalid DDR edge latch')
    pos += config[8]
    cycle, retires = take('<QQ')
    pos += 1 << 27  # qualified harness DDR backing is always 128 MiB
    count, = take('<Q')
    need(count <= 1024, 'invalid outstanding DDR FIFO extent')
    pos += count * 24  # three uint64_t fields, individually serialized
    burst, = take('<B')
    take('<IIiI')  # waddr, wrem, VGA phase, VGA LCG; fixed 32-bit fields
    initialized, = take('<B')
    need(burst in (0, 1) and initialized == 1, 'invalid host/model state flags')
    root_check, = take('<Q')
    need(root_check == checksum, 'model layout checksum mismatch at parsed host boundary')
    remainder = len(data) - pos - payload_size - 8 - 8
    need(remainder > 0 and remainder % 2 == 0, 'invalid file extent')
    context_size = remainder // 2
    need(8 <= context_size <= 4096, 'invalid serialized context size')
    start = pos + context_size
    package = start + payload_size
    need(struct.unpack_from('<Q', data, package)[0] == package_checksum, 'package checksum mismatch')
    need(data[pos:start] == data[package+8:package+8+context_size], 'model contexts differ')
    need(data[package+8+context_size:] == b'vltsaved', 'unexpected trailer/extra bytes')
    return start, dict(cycle=cycle, retires=retires, config=config, spi=spi,
                       read_edge=read_edge, context_bytes=context_size, serialized_fields_bytes=payload_size)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--obj', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    need(not args.out.exists() and not args.out.is_symlink(), 'output already exists')
    bundle = verify_bundle(args.bundle)
    obj = args.obj.resolve(strict=True)
    need(digest(obj / 'ao486sim_ven') == digest(bundle / 'ao486sim_ven'), 'model executable differs from bundle')
    header, root, package, syms = [obj / n for n in (
        'Vsystem___024root.h', 'Vsystem___024root__Slow.cpp',
        'Vsystem_ventium_pkg__Slow.cpp', 'Vsystem__Syms__Slow.cpp')]
    sym_body = syms.read_text().split('void Vsystem__Syms::__Vserialize(VerilatedSerialize& os) {', 1)[1].split(
        'void Vsystem__Syms::__Vdeserialize', 1)[0]
    need(re.sub(r'\s+|//[^\n]*', '', sym_body) ==
         'os<<__Vm_didInit;TOP.__Vserialize(os);TOP__ventium_pkg.__Vserialize(os);}',
         'unknown hierarchy serialization')
    check, fields, size = serializer_layout(root.read_text(), declarations(header.read_text()))
    pkg_check, pkg_fields, pkg_size = serializer_layout(package.read_text(), {}, 'Vsystem_ventium_pkg')
    need(not pkg_fields and pkg_size == 0, 'stateful package unsupported')
    files = [header, root, package, syms, obj / 'ao486sim_ven', bundle / 'gameplay.snap']
    before = {str(p): digest(p) for p in files}
    with (bundle / 'gameplay.snap').open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        start, meta = snapshot_payload(data, check, size, pkg_check)
        prefix = 'system__DOT__vga__DOT__'
        registers, arrays = {}, {}
        for name, field in fields.items():
            if not name.startswith(prefix):
                continue
            raw = data[start+field['offset']:start+field['offset']+field['size']]
            short = name[len(prefix):]
            if not field['dimensions']:
                registers[short] = int.from_bytes(raw, 'little')
            elif re.fullmatch(r'(plane_ram_[0-3]|dac_ram|internal_palette_ram)__DOT__mem', short):
                arrays[short] = (raw, field)
        need(len(arrays) == 6, 'missing VGA arrays')
    need(all(digest(p) == h for p, h in before.items()), 'inputs changed during extraction')
    args.out.mkdir(parents=True)
    for name, (raw, _) in arrays.items():
        with (args.out / (name+'.bin')).open('xb') as stream:
            stream.write(raw)
    receipt = dict(scope=__doc__, source_sha256=before, snapshot=meta, registers=registers,
                   arrays={name: field for name, (_, field) in arrays.items()},
                   model_checksum=hex(check), input_drift=[])
    (args.out / 'vga.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print('NATIVE-VGA-EXTRACT-OK', args.out, 'cycle', meta['cycle'])


if __name__ == '__main__':
    main()
