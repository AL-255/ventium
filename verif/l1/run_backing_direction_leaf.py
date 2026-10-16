"""Bounded four-state comparison of the exact old/new backing drive equations."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import prepare_backing_direction as recipe
from prepare_backing_pair_payload import FIELDS, rename

HERE = Path(__file__).resolve().parent
ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def fixture(source, mode):
    body = ''.join(f'  logic [{w-1}:0] {p}{n};\n'
                   for p in ('old_', 'new_') for n, w in FIELDS.items())
    body += rename(recipe.block(source), 'old_')
    new = recipe.changed_block(source)
    mutations = {
        'late-direction': ('if ((st == L1_IDLE) && !stream_path',
                           'if (c_req && (st == L1_IDLE) && !stream_path'),
        'fill-write': ("    m_we = 1'b0;", "    m_we = (st == L1_FILL);"),
        'lost-admission': ('m_req=c_pair_req && c_pair_intent_ready;',
                           'm_req=c_pair_req;'),
        'wrong-payload': ('m_addr=c_pair_addr;', 'm_addr=c_addr;'),
    }
    if mode != 'positive':
        before, after = mutations[mode]
        assert before in new
        new = new.replace(before, after, 1)
    body += rename(new, 'new_')
    text = (HERE/'tb_backing_payload_mux.sv').read_text()
    assert text.count('  // EXTRACTED_EQUATIONS') == 1
    text = text.replace('  // EXTRACTED_EQUATIONS', body)
    # Every other output is compared unconditionally, including inactive data.
    for p in ('old_', 'new_'):
        assert text.count(p+'m_req,'+p+'m_we,') == 1
        text = text.replace(p+'m_req,'+p+'m_we,', p+'m_req,')
    anchor = "      if (new_m_req === 1'b1) transactions++;"
    assert text.count(anchor) == 1
    check = """      if ((old_m_req === 1'b1 || c_req === 1'b1) &&
          old_m_we !== new_m_we)
        $fatal(1,"BACKING-DIRECTION-MISMATCH consumed direction");
`ifdef VEN_P54_DUAL_STORE_PAIR
      // This checks the new hint itself, not only conditional equivalence.
      expected_direction=0;
      if (st==L1_IDLE && !stream_path
`ifndef VEN_P54_LOAD_STORE_PAIR
          && c_we
`endif
         ) expected_direction=1;
      if (new_m_we !== expected_direction)
        $fatal(1,"BACKING-DIRECTION-MISMATCH late/incorrect direction hint");
      if (c_req===1'b0 && new_m_we===1'b1) early_hints++;
`else
      if (old_m_we !== new_m_we)
        $fatal(1,"BACKING-DIRECTION-MISMATCH default changed");
`endif
"""
    text = text.replace(anchor, check+anchor)
    text = text.replace('  integer checks=0,',
        '  reg expected_direction;\n  integer early_hints=0;\n  integer checks=0,')
    text = text.replace('    $display("BACKING-MUX-OK',
        '`ifdef VEN_P54_DUAL_STORE_PAIR\n'
        '    if(early_hints==0) $fatal(1,"BACKING-DIRECTION-COVERAGE");\n'
        '`endif\n    $display("BACKING-DIRECTION-OK')
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for n in ('source', 'out'): ap.add_argument('--'+n, type=Path, required=True)
    a = ap.parse_args(); source = a.source.resolve(strict=True); out = a.out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    assert out.parent.resolve(strict=True)==ROOT and not out.exists()
    assert ROOT.stat().st_dev!=HERE.stat().st_dev and os.access(ROOT,os.W_OK)
    assert shutil.disk_usage(ROOT).free>4*1024**3 and os.environ['INVOCATION_ID']
    assert sorted(os.sched_getaffinity(0))==[12,13]
    group=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((group/'memory.max').read_text())<=512*1024**2
    assert (group/'memory.swap.max').read_text().strip()=='0'
    assert 0<int((group/'pids.max').read_text())<=32
    assert sha(source)==recipe.PARENT
    inputs=[source,Path(__file__),Path(recipe.__file__),HERE/'prepare_backing_payload_mux.py',
        HERE/'prepare_backing_pair_payload.py',HERE/'tb_backing_payload_mux.sv',
        Path('/usr/bin/iverilog'),Path('/usr/bin/vvp')]
    pins={str(p.resolve()):sha(p) for p in inputs}
    original=source.read_text(); changed=recipe.transform(original)
    out.mkdir()
    with (out/'ven_l1d.sv').open('x') as f: f.write(changed)
    profiles=dict(default=[],dual=['VEN_P54_DUAL_STORE_PAIR'],
        full=['VEN_P54_DUAL_STORE_PAIR','VEN_P54_LOAD_STORE_PAIR'])
    jobs=[(p,'positive') for p in profiles]+[('full',m) for m in
        ('late-direction','fill-write','lost-admission','wrong-payload')]
    def save(name,obj):
        with (out/name).open('x') as f: json.dump(obj,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],jobs=jobs))
    begin=time.monotonic(); rows=[]; errors=[]
    def run(job):
        profile,mode=job; folder=out/(profile+'-'+mode); folder.mkdir()
        sv=folder/'tb.sv'; exe=folder/'test.vvp'
        with sv.open('x') as f: f.write(fixture(original,mode))
        command=['/usr/bin/iverilog','-g2012','-s','tb','-o',str(exe),
            *['-D'+d for d in profiles[profile]],str(sv)]
        with (folder/'build.log').open('x') as f:
            built=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=30)
        assert built.returncode==0,(profile,mode,'compile failed')
        with (folder/'native.log').open('x') as f:
            child=subprocess.Popen(['/usr/bin/vvp',str(exe)],stdout=f,stderr=subprocess.STDOUT)
            affinity=sorted(os.sched_getaffinity(child.pid)); assert affinity==[12,13]
            try: status=child.wait(timeout=120)
            except BaseException: child.kill(); child.wait(); raise
        log=(folder/'native.log').read_text()
        passed=(status==0 and 'BACKING-DIRECTION-OK checks=524520' in log) if mode=='positive' else (
            status==1 and re.search(r'BACKING-(DIRECTION|MUX)-MISMATCH',log) is not None)
        row=dict(profile=profile,mode=mode,passed=passed,native_exit=status,
            compile_exit=built.returncode,command=command,affinity=affinity,
            artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()})
        print(json.dumps({k:row[k] for k in ('profile','mode','passed','native_exit')}),flush=True)
        return row
    try:
        with ThreadPoolExecutor(max_workers=2) as pool: rows=list(pool.map(run,jobs))
    except Exception as exc: errors.append(repr(exc))
    stable=all(sha(p)==h for p,h in pins.items())
    events={k:int(v) for k,v in (s.split() for s in (group/'memory.events').read_text().splitlines())}
    result=dict(passed=not errors and stable and len(rows)==len(jobs) and all(r['passed'] for r in rows)
        and not any(events[k] for k in ('oom','oom_kill','oom_group_kill')),
        rows=rows,errors=errors,pins_unchanged=stable,memory_events=events,
        seconds=time.monotonic()-begin,memory_peak=int((group/'memory.peak').read_text()),
        derivative_sha256=sha(out/'ven_l1d.sv'),sequential_cache=False,real_axi=False,
        whole_core=False,physical_fpga=False,gameplay_ipc=None,fmax_mhz=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
