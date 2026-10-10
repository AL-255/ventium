"""Generate a unit shell from the exact legacy WB ports and core enum prefix.

No replacement writeback logic or locally invented state encoding. Generated
files are test-only; neither input RTL file is edited.
"""
import argparse
from pathlib import Path
import re


def generate(writeback, core, body):
    parts = re.split(r'^module core\b', core, flags=re.M)
    if len(parts) != 2 or parts[0].count('} state_e;') != 1:
        raise ValueError('core type prefix missing or ambiguous')
    match = re.search(r'^\s*// ===== INPUTS.*?^\);', writeback, re.M|re.S)
    if not match:
        raise ValueError('actual writeback port list not found')
    declarations=[]; defaults=[]; names=[]
    for original in match.group(0).splitlines()[1:-1]:
        line=original.split('//',1)[0].strip()
        if not line or line==',': continue
        if line.startswith('`'):
            if not re.fullmatch(r'`(?:ifdef \w+|ifndef \w+|else|endif)',line):
                raise ValueError('unsupported port directive '+line)
            declarations.append(line); defaults.append(line); continue
        item=re.fullmatch(r'(input|output)\s+(.+?)\s+(\w+)(\s*\[\d+\])?\s*,?',line)
        if not item: raise ValueError('unsupported port declaration '+line)
        direction,kind,name,array=item.groups()
        if name in names: raise ValueError('duplicate port '+name)
        names.append(name)
        declarations.append(f'  {kind} {name}{array or ""};')
        if direction=='input':
            if array: defaults.append(f"  foreach ({name}[i]) {name}[i] = '0;")
            else:
                zero="'0" if kind.startswith('logic') else f"{kind}'('0)"
                defaults.append(f'  {name} = {zero};')
    if not {'state','q_fxop','fp_we_fstat','fp_we_sti','pipe_fp_live_arm'} <= set(names):
        raise ValueError('missing required real ports')
    anchor='  // GENERATED_INPUT_DEFAULTS'
    if body.count(anchor)!=1: raise ValueError('test default anchor missing or ambiguous')
    body=body.replace(anchor,'\n'.join(defaults))
    packages=('ventium_pkg','ventium_alu_pkg','ventium_decode_pkg',
              'fpu_x87_pkg','ventium_x87_pkg','ventium_sys_pkg')
    shell='module tb_fst_legacy;\n'+'\n'.join(f'import {p}::*;' for p in packages)+'\n'
    shell+='\n'.join(declarations)+'\nfpu_writeback dut (.*);\n'+body+'\nendmodule\n'
    return parts[0],shell


if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args(); a.out.mkdir()
    prefix,shell=generate((a.source/'rtl/core/fpu_writeback.sv').read_text(),
        (a.source/'rtl/core/core.sv').read_text(),Path(__file__).with_name('fst_legacy_body.svh').read_text())
    for name,text in (('state_types.sv',prefix),('tb_fst_legacy.sv',shell)):
        with (a.out/name).open('x') as stream: stream.write(text)
