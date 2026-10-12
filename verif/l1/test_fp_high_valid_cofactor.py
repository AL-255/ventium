"""Native extracted-source wide-valid/consumer miter and deliberate mutations.

Not a sequential cache/core proof. No state is injected into any core here.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

import prepare_fp_high_valid_cofactor as recipe


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def renamed(text, names):
    return re.sub(r'\b('+ '|'.join(map(re.escape, names))+r')\b',
                  lambda m: names[m[0]], text)


def fixture(inputs, mutant=None):
    l1, seam, core = (inputs[p] for p in recipe.PARENTS)
    changed = {p:recipe.transform(s,p) for p,s in inputs.items()}
    # All extraction anchors are protected by the complete predecessor hashes.
    body = '  assign c_req = l1d_c_req;\n'
    for name in ('rd_match','mc_lookup_old','mc_lookup_prime','mc_lookup_next',
                 'window_reuse','shadow_reuse'):
        rows = re.findall(r'  assign '+name+r'\s*=.*?;\n',l1,re.S)
        rows = [r for r in rows if "= 1'b0;" not in r]
        assert len(rows)==1, name
        body += rows[0]
    body += '  assign hit = mc_lookup_next ? |tag_prime_hit : |tag_current_hit;\n'
    ack = re.findall(r'  always_comb begin\n    c_read_ack = .*?\n  end\n',l1,re.S)
    assert len(ack)==1
    body += ack[0]
    old=recipe.assignment(l1,'c_rdata_hi_valid')
    body += renamed(old, {'c_rdata_hi_valid':'old_hi'})
    new=recipe.L1
    mutations={
        'lost-next-owner': ('!(c_next_req && rd_match)', "1'b1"),
        'lost-residency': ('&& fp_high_current_hit &&', '&&'),
        'lost-full-line': ('rd_full_line_q &&', ''),
        'wrong-extent': ("c_addr[4:0] <= 5'd24", "c_addr[4:0] <= 5'd28"),
    }
    if mutant in mutations:
        before,after=mutations[mutant]
        assert new.count(before)==1
        new=new.replace(before,after)
    body += renamed(new, {'c_rdata_hi_valid':'new_hi'})
    for name in ('l1d_c_req','core_read_ack'):
        body += recipe.assignment(seam,name)
    body += renamed(recipe.assignment(seam,'core_rdata_hi_valid'), {'core_rdata_hi_valid':'old_seam'})
    body += renamed(recipe.assignment(changed['rtl/mem/ventium_l1_axi.sv'],'core_rdata_hi_valid'),
                    {'core_rdata_hi_valid':'new_seam','l1d_c_rdata_hi_valid':'new_hi'})
    for name,label in (('fp_load64_take','take'),('fp_shared_load_cmd','cmd')):
        body += renamed(recipe.assignment(core,name),
                        {name:'old_'+label,'fp_load64_take':'old_take'})
        new=recipe.assignment(changed['rtl/core/core.sv'],name)
        if mutant=='narrow-without-ack' and label=='cmd':
            assert new.count('mem_read_ack &&')==1
            new=new.replace('mem_read_ack &&', '')
        body += renamed(new, {name:'new_'+label,'fp_load64_take':'new_take',
                              'bus_rdata_hi_valid':'new_seam'})
    # Icarus does not implement the SV inside operator. This mechanical
    # three-way equality expansion preserves its exact binary meaning.
    before='q_fxop inside {FX_AR_I32, FX_FCOM_M32, FX_FCOM_M64}'
    assert body.count(before)==2
    body=body.replace(before,'(q_fxop == FX_AR_I32 || q_fxop == FX_FCOM_M32 || q_fxop == FX_FCOM_M64)')
    template=Path(__file__).with_name('tb_fp_high_valid_cofactor.sv').read_text()
    assert template.count('  // EXTRACTED_EQUATIONS')==1
    return template.replace('  // EXTRACTED_EQUATIONS',body)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    root=args.out.resolve(); parent=args.parent.resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert scratch.stat().st_dev!=Path(__file__).stat().st_dev
    inputs={p:(parent/p).read_text() for p in recipe.PARENTS}
    pins={str(parent/p):sha(parent/p) for p in inputs}
    for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),
              Path(__file__).with_name('tb_fp_high_valid_cofactor.sv').resolve()):
        pins[str(p)]=sha(p)
    for path,source in inputs.items():
        changed=recipe.transform(source,path)
        # Only the listed assignments and simulation witnesses may change.
        for name,new,clock,reset in recipe.replacements(source,path):
            old=recipe.assignment(source,name)
            assert changed.count(new+recipe.witness(old,name,clock,reset))==1
        for bad in (source+'\n',changed):
            try: recipe.transform(bad,path)
            except ValueError: pass
            else: raise AssertionError('accepted source drift/reapplication')
    root.mkdir(); begin=time.monotonic()
    result=dict(passed=False,pins=pins,rows=[],errors=[],whole_core=False,
                invocation=os.environ.get('INVOCATION_ID'),affinity=sorted(os.sched_getaffinity(0)),
                gameplay_ipc=None,fmax_mhz=None)
    defines=['VEN_FP_LOAD_EARLY_CMD','VEN_PIPE_MEM_CHAIN','VEN_PIPE_REG_LOAD_PRIME',
             'VEN_L1D_PRIME_UNDER_FILL','VEN_L1D_CODE_BUFFER','VEN_L1D_WINDOW_REUSE',
             'VEN_L1D_TWO_WINDOW_REUSE','VEN_L1D_CODE_WORD_REUSE','VEN_L1D_HIT_STREAM',
             'VEN_FP_SCALAR_LOAD_CMD']
    try:
        for mode in (None,'lost-next-owner','lost-residency','lost-full-line',
                     'wrong-extent','narrow-without-ack'):
            label=mode or 'positive'; folder=root/label; folder.mkdir()
            sv=folder/'tb.sv'; sv.write_text(fixture(inputs,mode)); binary=folder/'test.vvp'
            command=['iverilog','-g2012','-s','tb','-o',str(binary),
                     *['-D'+d for d in defines],str(sv)]
            with (folder/'build.log').open('x') as f:
                build=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=20)
            assert build.returncode==0, (label,'build')
            with (folder/'run.log').open('x') as f:
                run=subprocess.run(['vvp',str(binary)],stdout=f,stderr=subprocess.STDOUT,timeout=45)
            log=(folder/'run.log').read_text()
            if mode:
                assert run.returncode==1 and 'FP-HIGH-VALID-MISMATCH' in log, (label,log)
            else:
                assert run.returncode==0 and 'FP-HIGH-VALID-OK checks=509600 ' in log, log
            result['rows'].append(dict(label=label,native_exit=run.returncode,log=log,
                command=command,artifacts={str(p):sha(p) for p in (sv,binary,folder/'run.log',folder/'build.log')}))
        result['passed']=True
    except Exception as exc:
        result['errors'].append(repr(exc))
    finally:
        result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
        result['passed'] &= result['pins_unchanged']
        (root/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
