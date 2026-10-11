#!/usr/bin/env python3
"""Bounded native real-U-pipe A/B leaf; no core build, synthesis or FPGA claim."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback
from prepare_u_alu_shared import transform

REPO=Path(__file__).resolve().parents[2]


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def save(p,v):
    with p.open('x') as f:json.dump(v,f,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('source','defines','out'):ap.add_argument('--'+name,type=Path,required=True)
    args=ap.parse_args()
    source=args.source.resolve(strict=True);definitions=args.defines.resolve(strict=True)
    root=args.out.resolve();scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and not root.exists() and root!=scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>4*1024**3
    assert os.sched_getaffinity(0)=={10}
    defs=definitions.read_text().splitlines()
    assert len(defs)==len(set(defs))==154
    assert {'VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC'}<=set(defs)
    assert 'SYNTHESIS' not in defs
    files=[source/'rtl/core'/name for name in ('ventium_alu_pkg.sv','ventium_decode_pkg.sv','u_pipe.sv')]
    original=files[-1].read_text()
    changed=transform(original)
    assert changed.count('module u_pipe\n')==1 and changed.count('endmodule : u_pipe')==1
    changed=changed.replace('module u_pipe\n','module u_pipe_shared\n').replace(
        'endmodule : u_pipe','endmodule : u_pipe_shared')
    borrow=changed.replace('      fl=cur&32\'hffff_f72a;',
        "      if(op==ALU_SBB) cf=~cf;\n      fl=cur&32'hffff_f72a;")
    immediate=changed.replace('else if (d.use_imm) fp_bop = d.imm;',
                              'else if (d.use_imm) fp_bop = u_src_val;')
    shift=changed.replace('u_shcnt = u_d.shift_cl ? u_src_val[4:0] : u_d.shimm;',"u_shcnt = 5'd0;")
    assert all(v!=changed for v in (borrow,immediate,shift))
    root.mkdir()
    variants=[('reference',original,False),('positive',changed,False),('bad-borrow',borrow,True),
              ('bad-immediate',immediate,True),('bad-shift',shift,True)]
    fixture=Path(__file__).with_name('tb_u_alu_shared.sv')
    for name,text,_ in variants:
        with (root/(name+'.sv')).open('x') as f:f.write(text)
    paths=[*files,fixture,definitions,Path(__file__),Path(__file__).with_name('prepare_u_alu_shared.py'),
           *(root/(name+'.sv') for name,_,_ in variants)]
    pins={str(p):sha(p) for p in paths}
    save(root/'started.json',dict(pins=pins,definitions=defs,invocation=os.environ['INVOCATION_ID'],
        whole_core=False,production_rtl_modified=False,no_vivado_or_verilator=True,
        separate_native_processes=True,reference_record_width=134,reference_records=65664))
    begin=time.monotonic();rows=[];error=None
    try:
        golden=root/'reference.bits'
        for name,_,negative in variants:
            binary=root/(name+'.vvp')
            # The oracle is the actual unchanged parent module, run separately
            # to avoid Icarus shared-package-function delta-cycle feedback.
            selected=files[-1] if name=='reference' else root/(name+'.sv')
            cmd=['iverilog','-g2012','-s','tb_u_alu_shared','-o',str(binary),
                 *['-D'+d for d in defs],*(['-DU_ALU_REFERENCE'] if name=='reference' else []),
                 *map(str,files[:-1]),str(selected),str(fixture)]
            save(root/(name+'-command.json'),cmd)
            with (root/(name+'-compile.log')).open('x') as f:
                compiled=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=30)
            assert compiled.returncode==0,(name,'compile',compiled.returncode)
            with (root/(name+'.log')).open('x') as f:
                native=subprocess.run(['vvp',str(binary),'+golden='+str(golden)],
                    stdout=f,stderr=subprocess.STDOUT,timeout=180)
            log=(root/(name+'.log')).read_text()
            passed=(native.returncode==0 and 'U-ALU-SHARED-OK checks=65664' in log) if not negative else (
                native.returncode==1 and 'U-ALU-SHARED-MISMATCH' in log and 'U-ALU-SHARED-OK' not in log)
            row=dict(name=name,passed=passed,native_exit=native.returncode,
                log_sha256=sha(root/(name+'.log')),binary_sha256=sha(binary))
            rows.append(row);print(json.dumps(row),flush=True)
            assert passed,row
            if name=='reference':
                records=golden.read_text().splitlines()
                assert len(records)==65664 and all(len(r)==134 and set(r)<=set('01xz') for r in records)
                pins[str(golden)]=sha(golden)
                save(root/'reference-receipt.json',dict(sha256=sha(golden),
                    records=len(records),bits_per_record=134,native_exit=native.returncode,
                    no_mask_or_normalization=True))
            assert sha(golden)==pins[str(golden)],'reference drift'
    except Exception as exc:error=dict(error=repr(exc),traceback=traceback.format_exc())
    stable=all(sha(Path(p))==h for p,h in pins.items())
    result=dict(passed=error is None and stable,error=error,rows=rows,pins_unchanged=stable,
        seconds=time.monotonic()-begin,whole_core=False,canonical_gate_passed=False,
        fpga_qualified=False,gameplay_ipc=None,frequency_mhz=None,production_rtl_modified=False)
    save(root/'closed.json',result);print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
