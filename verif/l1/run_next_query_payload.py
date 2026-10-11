#!/usr/bin/env python3
"""Source-extracted address cofactor proof; not a core/cache or timing pass."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from prepare_next_query_payload import OLD, NEW, transform, assignment, require_conjunct


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core-source', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    source, out = args.core_source.resolve(strict=True), args.out.resolve()
    here = Path(__file__).resolve().parent
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and shutil.disk_usage(scratch).free > 4*1024**3
    files = [source/'core_mem_chain.svh', source/'core_agi_resident_prime.svh', source/'core_ref_operand_prime.svh']
    assert sha(files[1]) == '4f35f4274b5e78e0dd9e4161db24db5b33442a7855e437ec27da9fe9aa3fb479'
    assert sha(files[2]) == 'b177c0355f020f435b78a7c94c5679454209033f10004427cfda755e20d98c7d'
    original = files[0].read_text(); changed = transform(original)
    for p, signal, guard in ((files[0],'mc_offer','mc_valid_q'),
                             (files[1],'agi_prime_offer','agi_prime_select'),
                             (files[2],'ref_prime_offer','ref_prime_select')):
        require_conjunct(assignment(p.read_text(),signal),guard)
    pins = {str(p):sha(p) for p in [*files,Path(__file__),here/'prepare_next_query_payload.py',
            here/'test_next_query_payload.py',here/'next_query_payload_leaf.svh',
            Path('/usr/bin/iverilog').resolve(),Path('/usr/bin/vvp').resolve()]}
    out.mkdir()
    def save(name, value):
        with (out/name).open('x') as f: json.dump(value,f,indent=2)
    def run(name, command, expected, marker=None, env=None):
        save(name+'.command.json',list(map(str,command)))
        with (out/(name+'.log')).open('x') as log:
            p = subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=30,env=env)
        assert p.returncode == expected, (name,p.returncode)
        if marker: assert marker in (out/(name+'.log')).read_text(), name
        return dict(name=name,native_exit=p.returncode,log_sha256=sha(out/(name+'.log')))
    start = time.monotonic(); result = dict(passed=False,runs=[],error=None,gameplay_ipc=None,whole_core=False,timing_mhz=None)
    try:
        with (out/'core_mem_chain.svh').open('x') as f: f.write(changed)
        result['runs'].append(run('recipe',['python3','-B',here/'test_next_query_payload.py'],0,
            env=dict(os.environ,NEXT_QUERY_PARENT=str(files[0]))))
        equations = '\n'.join('  assign '+name+' = '+expr+';' for name,expr in (
            ('reference_addr',assignment(original,'mem_next_addr')),
            ('candidate_addr',assignment(changed,'mem_next_addr')),
            ('mem_next_req',assignment(original,'mem_next_req'))))
        body = (here/'next_query_payload_leaf.svh').read_text()
        assert body.count('  // SOURCE_EXTRACTED_ASSIGNMENTS') == 1
        tb = out/'tb_next_query_payload.sv'
        with tb.open('x') as f: f.write('module tb_next_query_payload;\n'+body.replace('  // SOURCE_EXTRACTED_ASSIGNMENTS',equations)+'\nendmodule\n')
        binary = out/'test.vvp'
        result['runs'].append(run('build',['/usr/bin/iverilog','-g2012','-s','tb_next_query_payload','-o',binary,tb],0))
        for name, flag, expected in (('baseline',None,0),('mutant-owner','+mutant_owner',1),('mutant-live','+mutant_live',1)):
            result['runs'].append(run(name,['/usr/bin/vvp',binary]+([flag] if flag else []),expected,
                'NEXT_QUERY_PAYLOAD_EQ' if flag else 'NEXT-QUERY-PAYLOAD-OK samples=4096 offered=3232 unused=256'))
        for p in (tb,binary,out/'core_mem_chain.svh'): pins[str(p)] = sha(p)
        result['passed'] = True
    except Exception as error:
        import traceback
        result.update(error=repr(error),traceback=traceback.format_exc())
    result.update(seconds=time.monotonic()-start,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('pins.json',pins); save('closed.json',result)
    print(json.dumps(result))
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
