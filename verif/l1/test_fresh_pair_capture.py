"""Source-extracted native binary miter across feature profiles and mutants.

This is not a sequential cache, X/Z or whole-core proof. No expressions in the
changed predicate or its old dependency tree are manually translated to Python.
"""
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

import prepare_fresh_pair_capture as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def assignment(source, name):
    rows = re.findall(r'  (?:assign|wire) ' + name + r'\s*=.*?;', source, re.S)
    if len(rows) != 1:
        raise ValueError(('preprocessed assignment drift', name, len(rows)))
    return re.sub(r'^  wire ', '  assign ', rows[0]) + '\n'


def replace(source, old, new):
    if source.count(old) != 1:
        raise ValueError(('fresh-pair test anchor drift', old))
    return source.replace(old, new)


def fixture(old, new, flags):
    body = ''
    for name in ('stream_path','rd_match','mc_lookup_old','mc_lookup_prime',
                 'mc_lookup_next','lookup_addr','lookup_wstrb','set_c','tag_c',
                 'xline','rd_hit','window_reuse','shadow_reuse',
                 'fill_independent_hit','fill_forward_data_hit',
                 'fill_forward_code_hit','fill_forward_hit','do_rd_cap_legacy'):
        body += assignment(old, name)
    if 'VEN_PIPE_MEM_CHAIN' in flags:
        body += ''.join(assignment(old, n) for n in ('hit0','hit1','hit'))
    else:
        # No address selector in this profile. Abstract the current tag read
        # as two independent hit inputs; both old and new use the same hit.
        body += '  assign hit0=tag_current_hit[0];\n  assign hit1=tag_current_hit[1];\n'
        body += assignment(old,'hit')
    for name, feature in (('code_access','VEN_L1D_CODE_BUFFER'),
                          ('code_hit','VEN_L1D_CODE_BUFFER'),
                          ('code_word_reuse','VEN_L1D_CODE_WORD_REUSE')):
        body += assignment(old,name) if feature in flags else f"  assign {name}=1'b0;\n"
    extent = re.findall(r'  always_comb begin\n    c_x_hi = .*?\n  end\n', old, re.S)
    assert len(extent)==1
    body += extent[0]
    body += assignment(old,'pair_legacy_capture').replace('pair_legacy_capture','old_capture')
    for name in ('pair_fresh_current_hit','pair_fresh_saved_window'):
        body += f'  wire {name};\n' + assignment(new,name)
    body += assignment(new,'pair_legacy_capture').replace('pair_legacy_capture','new_capture')
    return replace((HERE/'tb_fresh_pair_capture.sv').read_text(), '  // EXTRACTED_EQUATIONS', body)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    source_path=args.source.resolve(strict=True);root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert scratch.stat().st_dev!=HERE.stat().st_dev and shutil.disk_usage(scratch).free>4*1024**3
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert os.environ.get('INVOCATION_ID') and os.sched_getaffinity(0)==set(range(8))
    source=source_path.read_text();changed=recipe.transform(source)
    old=recipe.original_capture(source)
    assert replace(changed,recipe.NEW+recipe.witness(old),old)==source
    for bad in (source+'\n',changed):
        try: recipe.transform(bad)
        except ValueError: pass
        else: raise AssertionError('accepted source drift/reapplication')
    pins={str(p):sha(p) for p in (source_path,Path(__file__).resolve(),
        Path(recipe.__file__).resolve(),HERE/'tb_fresh_pair_capture.sv',
        REPO/'tools/build_scope.sh',Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'))}
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as f: json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0))))
    (root/'ven_l1d.sv').write_text(changed)
    common=['SYNTHESIS','VEN_P54_DUAL_HIT','VEN_P54_DUAL_HIT_LEGACY_CAPTURE',
        'VEN_P54_DUAL_LOAD_PAIR','VEN_L1D_FILL_FORWARD','VEN_L1D_HIT_UNDER_FILL',
        'VEN_L1D_HIT_STREAM','VEN_P54_DUAL_STORE_PAIR']
    modes=[]
    for chain in (False,True):
        for byte in (False,True):
            for code in (False,True):
                for windows in range(3):
                    label=f'chain{int(chain)}-byte{int(byte)}-code{int(code)}-window{windows}'
                    flags=common.copy()
                    if chain: flags+=['VEN_PIPE_MEM_CHAIN','VEN_PIPE_REG_LOAD_PRIME','VEN_L1D_PRIME_UNDER_FILL']
                    if byte: flags+=['VEN_P54_DUAL_BYTE_LOAD_PAIR']
                    if code: flags+=['VEN_L1D_CODE_BUFFER','VEN_L1D_CODE_WORD_REUSE','VEN_L1D_CODE_STREAM']
                    if windows: flags+=['VEN_L1D_WINDOW_REUSE']
                    if windows==2: flags+=['VEN_L1D_TWO_WINDOW_REUSE']
                    modes.append((label,flags,None))
    full=modes[-1][1]
    modes += [('data-under-ifill',full+['VEN_L1D_DATA_UNDER_IFILL'],None),
              ('no-fill', [f for f in full if f not in ('VEN_L1D_FILL_FORWARD',
                'VEN_L1D_HIT_UNDER_FILL','VEN_L1D_PRIME_UNDER_FILL','VEN_L1D_CODE_STREAM')],None)]
    mutations={
        'wrong-tags': ('assign pair_fresh_current_hit = |tag_current_hit;',
                       'assign pair_fresh_current_hit = |tag_prime_hit;'),
        'lost-window': ('window_valid_q &&',"1'b0 &&"),
        'lost-shadow': ('shadow_valid_q &&',"1'b0 &&"),
        'lost-flush': ("!flush_all && (c_addr[4:0] <= 5'd28)","(c_addr[4:0] <= 5'd28)"),
        'lost-byte-extent': ("!flush_all && (c_addr[4:0] <= 5'd28)",'!flush_all'),
        'lost-snoop': (' && !snoop_inv_valid',''),
        'lost-owner': ('!golden && !rd_armed &&','!golden &&'),
        'lost-alignment': ("((c_wstrb == 4'hf) && (c_addr[1:0] == 2'd0)))",
                           "(c_wstrb == 4'hf))"),
    }
    modes += [(label,full,edit) for label,edit in mutations.items()]
    begin=time.monotonic()
    def run(mode):
        label,flags,edit=mode;folder=root/label;folder.mkdir()
        row=dict(label=label,flags=flags,expected_failure=edit is not None)
        try:
            candidate=changed
            if edit:
                # Mutate only the actual new predicate, never its reference.
                candidate=replace(changed,recipe.NEW,replace(recipe.NEW,*edit))
            new_sv=folder/'candidate.sv';new_sv.write_text(candidate)
            paths=[]
            for name,sv in (('old',source_path),('new',new_sv)):
                pp=folder/(name+'.pp.sv')
                cmd=['/usr/bin/iverilog','-g2012','-E','-o',str(pp),*['-D'+f for f in flags],str(sv)]
                got=subprocess.run(cmd,text=True,capture_output=True,timeout=20)
                (folder/(name+'.preprocess.log')).write_text(got.stdout+got.stderr)
                assert got.returncode==0,got.stderr
                paths.append(pp)
            tb=folder/'tb.sv';tb.write_text(fixture(*(p.read_text() for p in paths),flags))
            binary=folder/'test.vvp'
            cmd=['/usr/bin/iverilog','-g2012','-s','tb','-o',str(binary),*['-D'+f for f in flags],str(tb)]
            got=subprocess.run(cmd,text=True,capture_output=True,timeout=20)
            (folder/'build.log').write_text(got.stdout+got.stderr)
            row.update(command=cmd,build_exit=got.returncode)
            assert got.returncode==0,got.stderr
            got=subprocess.run(['/usr/bin/vvp',str(binary)],text=True,capture_output=True,timeout=120)
            log=got.stdout+got.stderr;(folder/'run.log').write_text(log)
            row['native_exit']=got.returncode
            assert got.returncode==(1 if edit else 0),log
            marker='FRESH-PAIR-MISMATCH' if edit else 'FRESH-PAIR-CAPTURE-OK checks=179264'
            assert marker in log,log
            row.update(passed=True,coverage=log.strip(),artifacts={str(p):sha(p) for p in
                (new_sv,*paths,tb,binary,folder/'build.log',folder/'run.log')})
        except Exception as exc:
            row.update(passed=False,error=repr(exc))
        save(label+'/closed.json',row)
        print(label,'PASS' if row['passed'] else row.get('error'),flush=True)
        return row
    with ThreadPoolExecutor(max_workers=8) as pool: rows=list(pool.map(run,modes))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=stable and all(r['passed'] for r in rows),pins=pins,pins_unchanged=stable,
        rows=rows,seconds=time.monotonic()-begin,derivative_sha256=sha(root/'ven_l1d.sv'),
        whole_core=False,sequential_cache=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
