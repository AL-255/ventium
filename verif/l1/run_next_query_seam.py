#!/usr/bin/env python3
"""Prove inactive next-address changes cannot select a lookup across the seam.

Uses the real cache map and source-extracted integration/lookup equations, not
the whole cache/core. Native whole-core and FPGA qualification remain separate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from prepare_next_query_payload import assignment, transform


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def raw_assignment(source, name):
    match = re.search(r'^  assign '+re.escape(name)+r'\s*=.*?;', source, re.M | re.S)
    if not match:
        raise ValueError('missing source assignment: '+name)
    return match[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    core = args.core.resolve(strict=True)
    out = args.out.resolve()
    here = Path(__file__).resolve().parent
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    build = json.loads((core/'build-started.json').read_text())
    closed = json.loads((core/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
    pins = build['pins'].copy()
    assert all(sha(p) == h for p,h in pins.items())
    rtl = core/'candidate/rtl'
    source = (rtl/'core/core_mem_chain.svh').read_text()
    changed = transform(source)
    seam = (rtl/'mem/ventium_l1_axi.sv').read_text()
    leaf = (rtl/'mem/ven_l1d.sv').read_text()
    equations = [raw_assignment(seam,n) for n in ('mc_next_enable','core_next_ready')]
    for name in ('c_next_req','c_next_commit','c_next_cacheable'):
        value = re.findall(r'\.'+name+r'\(([^\n]+)\),', seam)
        assert len(value) == 1
        equations.append('  assign '+name+' = '+value[0]+';')
    equations += [raw_assignment(leaf,n) for n in ('mc_lookup_old','mc_lookup_prime',
        'mc_lookup_next','lookup_addr','c_next_ready','mc_capture_next')]
    payload = '\n'.join('  assign '+n+' = '+expr+';' for n,expr in (
        ('reference_addr',assignment(source,'mem_next_addr')),
        ('candidate_addr',assignment(changed,'mem_next_addr')),
        ('mem_next_req',assignment(source,'mem_next_req'))))
    body = (here/'next_query_seam_leaf.svh').read_text()
    assert body.count('// SOURCE_EXTRACTED_SEAM') == body.count('// SOURCE_EXTRACTED_PAYLOAD') == 1
    text = body.replace('  // SOURCE_EXTRACTED_SEAM','\n'.join(equations)).replace(
        '  // SOURCE_EXTRACTED_PAYLOAD',payload)
    # A deliberate integration defect must make unused addresses observable.
    mutant = text.replace('assign c_next_req = core_next_req && mc_next_enable;',
                          'assign c_next_req = mc_next_enable;')
    assert mutant != text
    files = [Path(__file__),here/'next_query_seam_leaf.svh',here/'prepare_next_query_payload.py',
             core/'build-started.json',core/'build-closed.json',
             Path('/usr/bin/iverilog').resolve(),Path('/usr/bin/vvp').resolve()]
    pins.update({str(p):sha(p) for p in files})
    out.mkdir()
    def save(name,value):
        with (out/name).open('x') as f: json.dump(value,f,indent=2)
    result = dict(passed=False,runs=[],errors=[],whole_core=False,gameplay_ipc=None)
    start = time.monotonic()
    try:
        for profile in ('idle','under-fill'):
            for name,body in (('positive',text),('mutant-unguarded',mutant)):
                stem=profile+'-'+name
                tb=out/(stem+'.sv'); tb.write_text(body)
                binary=out/(stem+'.vvp')
                command=['/usr/bin/iverilog','-g2012','-s','tb_next_query_seam',
                         '-DVEN_L1D_CODE_BUFFER']
                if profile=='under-fill': command.append('-DVEN_L1D_PRIME_UNDER_FILL')
                command += ['-o',str(binary),str(tb),str(rtl/'northbridge/ven_cachemap.sv')]
                for phase,cmd,expected in (('build',command,0),
                    ('run',['/usr/bin/vvp',str(binary)],0 if name=='positive' else 1)):
                    log=out/(stem+'-'+phase+'.log')
                    save(stem+'-'+phase+'.command.json',cmd)
                    with log.open('x') as f:
                        p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=45)
                    result['runs'].append(dict(name=stem+'-'+phase,native_exit=p.returncode,log_sha256=sha(log)))
                    assert p.returncode==expected,(stem,phase,p.returncode)
                    if phase=='run':
                        assert ('NEXT-QUERY-SEAM-OK' if name=='positive' else 'NEXT_QUERY_SEAM_EQ') in log.read_text()
                for p in (tb,binary): pins[str(p)] = sha(p)
        result['passed']=True
    except Exception as error:
        import traceback
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('pins.json',pins); save('closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
