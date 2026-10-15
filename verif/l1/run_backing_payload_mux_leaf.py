"""Bounded parallel four-state tests of the actual extracted backing producer."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import prepare_backing_payload_mux as recipe


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def fixture(source, mode):
    body=''
    for prefix in ('old_','new_'):
        for name,width in recipe.FIELDS.items():
            body+=f'  logic [{width-1}:0] {prefix}{name};\n'
    body+=recipe.rename(recipe.block(source),'old_')
    new=recipe.changed_block(source)
    mutations={
        'late-addr': ('    m_addr = c_addr;',"    m_addr = c_req ? c_addr : 32'd0;"),
        'wrong-v': ('      m_addr = c_pair_addr;','      m_addr = c_addr;'),
        'fill-strobe': ("      m_wstrb = 4'd0;","      m_wstrb = c_wstrb;"),
        'lost-credit': ('        m_pair_req = c_pair_intent_ready;',
                        '        m_pair_req = c_pair_req;'),
    }
    if mode!='positive':
        before,after=mutations[mode]
        assert before in new
        new=new.replace(before,after,1) # only selected branch; generic fallback unchanged
    body+=recipe.rename(new,'new_')
    template=Path(__file__).with_name('tb_backing_payload_mux.sv').read_text()
    assert template.count('  // EXTRACTED_EQUATIONS')==1
    return template.replace('  // EXTRACTED_EQUATIONS',body)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    source=args.source.resolve(strict=True); out=args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert scratch.stat().st_dev!=Path(__file__).stat().st_dev
    assert os.access(scratch,os.W_OK) and shutil.disk_usage(scratch).free>4*1024**3
    assert out.is_relative_to(scratch) and not out.exists() and out!=scratch
    assert sha(source)==recipe.PARENT and os.environ.get('INVOCATION_ID')
    assert os.sched_getaffinity(0)==set(range(13,17))
    inputs=(source,Path(__file__).resolve(),Path(recipe.__file__).resolve(),
            Path(__file__).with_name('prepare_backing_pair_payload.py'),
            Path(__file__).with_name('tb_backing_payload_mux.sv'),
            Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'))
    pins={str(p):sha(p) for p in inputs}
    original=source.read_text(); changed=recipe.transform(original)
    profiles=dict(default=[],dual=['VEN_P54_DUAL_STORE_PAIR'],
                  full=['VEN_P54_DUAL_STORE_PAIR','VEN_P54_LOAD_STORE_PAIR'])
    jobs=[(p,'positive') for p in profiles]+[
        ('full',m) for m in ('late-addr','wrong-v','fill-strobe','lost-credit')]
    out.mkdir(); (out/'ven_l1d.sv').write_text(changed)
    (out/'started.json').write_text(json.dumps(dict(pins=pins,
        invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0)),
        jobs=jobs,unfiltered=True,source=str(source)),indent=2)+'\n')
    begin=time.monotonic()

    def run(item):
        index,(profile,mode)=item; cpu=13+index%4
        folder=out/(profile+'-'+mode);folder.mkdir()
        sv=folder/'tb.sv';sv.write_text(fixture(original,mode)); binary=folder/'test.vvp'
        cmd=['taskset','-c',str(cpu),'/usr/bin/iverilog','-g2012','-s','tb','-o',str(binary),
             *['-D'+flag for flag in profiles[profile]],str(sv)]
        built=subprocess.run(cmd,capture_output=True,text=True,timeout=20)
        (folder/'build.log').write_text(built.stdout+built.stderr)
        assert built.returncode==0,(profile,mode,built.stderr)
        cmd_run=['taskset','-c',str(cpu),'/usr/bin/vvp',str(binary)]
        native=subprocess.run(cmd_run,capture_output=True,text=True,timeout=90)
        log=native.stdout+native.stderr;(folder/'run.log').write_text(log)
        expected=0 if mode=='positive' else 1
        marker='BACKING-MUX-OK checks=524520' if mode=='positive' else 'BACKING-MUX-MISMATCH'
        assert native.returncode==expected and marker in log,(profile,mode,native.returncode,log)
        row=dict(profile=profile,mode=mode,native_exit=native.returncode,output=log,
                 build_command=cmd,run_command=cmd_run,
                 files={str(p):sha(p) for p in (sv,binary,folder/'build.log',folder/'run.log')})
        print(json.dumps({k:v for k,v in row.items() if k not in ('files','build_command','run_command')}),flush=True)
        return row

    with ThreadPoolExecutor(max_workers=4) as pool:
        rows=list(pool.map(run,enumerate(jobs)))
    assert all(sha(p)==h for p,h in pins.items())
    closed=dict(passed=True,pins=pins,pins_unchanged=True,rows=rows,
        derivative_sha256=sha(out/'ven_l1d.sv'),seconds=time.monotonic()-begin,
        four_state_simulator=True,unfiltered_all_outputs=True,
        sequential_cache=False,real_axi_master=False,whole_core=False,
        gameplay_ipc=None,fmax_mhz=None)
    (out/'closed.json').write_text(json.dumps(closed,indent=2)+'\n')
    print(json.dumps({k:v for k,v in closed.items() if k not in ('pins','rows')}),flush=True)


if __name__=='__main__': main()
