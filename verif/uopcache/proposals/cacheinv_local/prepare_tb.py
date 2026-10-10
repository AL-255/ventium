"""Actual-decoder miter shell; no reimplementation of its reference predicate."""
import argparse
import re
from pathlib import Path


def generate(decoder, core, body):
    types = re.split(r'^module core\b', core, flags=re.M)
    if len(types) != 2 or types[0].count('} state_e;') != 1:
        raise ValueError('ambiguous/missing original state types')
    ports = re.search(r'^\(\n(.*?)^\);', decoder, re.M | re.S)
    if not ports:
        raise ValueError('original decoder ports not found')
    declarations, defaults, connections, names = [], [], [], set()
    for original in ports[1].splitlines():
        line = original.split('//', 1)[0].strip()
        if not line:
            continue
        item = re.fullmatch(r'(input|output)\s+(.+?)\s+(\w+)(\s*\[(?:\d+|NUM_GPR)\])?\s*,?', line)
        if not item:
            raise ValueError('unsupported actual port ' + line)
        direction, kind, name, array = item.groups()
        if name in names:
            raise ValueError('duplicate port ' + name)
        names.add(name)
        declarations.append(f'  {kind} {name}{array or ""};')
        connections.append(f'.{name}({"reference_bytes" if name == "ibuf" else name})')
        if direction == 'input' and name != 'ibuf_valid':
            if array:
                defaults.append(f"    foreach ({name}[i]) {name}[i]='0;")
            else:
                defaults.append(f"    {name}='0;")
    if not {'ibuf', 'ibuf_valid', 'd_cacheinv', 'd_unknown', 'cosim_en', 'soc_en'} <= names:
        raise ValueError('missing required original ports')
    if body.count('// GENERATED_INPUT_DEFAULTS') != 1:
        raise ValueError('missing/ambiguous default anchor')
    body = body.replace('// GENERATED_INPUT_DEFAULTS', '\n'.join(defaults))
    packages = ('ventium_pkg', 'ventium_alu_pkg', 'ventium_decode_pkg',
                'fpu_x87_pkg', 'ventium_x87_pkg', 'ventium_sys_pkg')
    shell = '`timescale 1ns/1ps\nmodule tb_cacheinv_local;\n'
    shell += '\n'.join(f'  import {p}::*;' for p in packages) + '\n'
    shell += '\n'.join(declarations) + '\n'
    shell += '  decode_stages reference_decoder (' + ',\n    '.join(connections) + ');\n'
    return types[0], shell + body + '\nendmodule\n'


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    prefix, shell = generate((args.source / 'rtl/core/decode_stages.sv').read_text(),
                             (args.source / 'rtl/core/core.sv').read_text(),
                             Path(__file__).with_name('body.svh').read_text())
    args.out.mkdir()
    for name, contents in (('state_types.sv', prefix), ('tb_cacheinv_local.sv', shell)):
        with (args.out / name).open('x') as f:
            f.write(contents)
