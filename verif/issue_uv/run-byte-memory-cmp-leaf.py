#!/usr/bin/env python3
"""Full-profile old/off/on decoder equivalence plus exact negative witness."""
import argparse,hashlib,importlib.util,json,os,re,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__)
    for n in ('source','profile','out'):p.add_argument('--'+n,type=Path,required=True)
    a=p.parse_args();scratch=Path('/home/yukidama/external/tmp').resolve()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and a.out.resolve().is_relative_to(scratch)
    a.out=a.out.resolve();a.out.mkdir()
    recipe=HERE/'prepare-byte-memory-cmp.py'
    spec=importlib.util.spec_from_file_location('recipe',recipe)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    original=a.source/module.TARGET
    control=a.out/'decode_control.sv'
    text=original.read_text();assert text.count('module decode\n')==1 and text.count('endmodule : decode')==1
    control.write_text(text.replace('module decode\n','module decode_control\n').replace('endmodule : decode','endmodule : decode_control'))
    candidate=a.out/'decode.sv';candidate.write_text(module.transform(text))
    tb=HERE/'tb_byte_memory_cmp.sv';lines=a.profile.read_text().splitlines();defs=set(lines)
    assert len(defs)==len(lines) and module.FLAG not in defs
    assert 'VEN_FAST_BYTE_ALU' in defs and all(re.fullmatch(r'VEN_[A-Z0-9_]+',x) for x in defs)
    packages=[a.source/'rtl'/s for s in ('ventium_pkg.sv','core/ventium_alu_pkg.sv','core/ventium_decode_pkg.sv','core/ventium_sys_pkg.sv')]
    files=packages+[a.source/'rtl/core/u_pipe.sv',control]
    pins={str(x.resolve()):sha(x) for x in [Path(__file__),recipe,original,control,candidate,tb,a.profile,*files]}
    result=dict(passed=False,variants=[],gameplay_ipc=None,standard_suite=False)
    try:
        for name,source,extra,negative in (
            ('candidate-off',candidate,set(),False),
            ('candidate',candidate,{module.FLAG},False),
            ('required-failure',original,{'BC_REQUIRE_NEW_BEHAVIOR'},True)):
            out=a.out/name;out.mkdir()
            cmd=['timeout','--kill-after=5s','180s','/tools/verilator/v5.046/bin/verilator',
                 '--binary','--timing','-sv','--assert','-j','32','-Wno-fatal','-Wno-UNUSED',
                 *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                 '--top-module','tb_byte_memory_cmp','--Mdir',str(out/'obj'),'-o','test',
                 *['+define+'+x for x in sorted(defs|extra)],*map(str,files),str(source),str(tb)]
            (out/'command.json').write_text(json.dumps(cmd,indent=2))
            with (out/'build.log').open('x') as f:
                rc=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,pass_fds=(9,)).returncode
            row=dict(name=name,build_exit=rc);result['variants'].append(row);assert rc==0
            with (out/'run.log').open('x') as f:
                rc=subprocess.run(['timeout','30s',out/'obj/test'],stdout=f,stderr=subprocess.STDOUT).returncode
            log=(out/'run.log').read_text();row.update(native_exit=rc,binary_sha256=sha(out/'obj/test'))
            if negative:
                assert rc in (1,134,-6) and 'BYTE-MEM-CMP-DECODE' in log and '%Fatal:' in log
                row['expected_assertion']=True
            else:
                assert rc==0
                m=re.search(r'BYTE-MEM-CMP-OK checks=(\d+) memory=(\d+) arithmetic=(\d+)',log);assert m
                row.update(checks=int(m[1]),memory=int(m[2]),arithmetic=int(m[3]))
        result['passed']=True
    finally:
        result['pins_unchanged']=all(sha(p)==h for p,h in pins.items());result['passed'] &= result['pins_unchanged']
        (a.out/'pins.json').write_text(json.dumps(pins,indent=2))
        (a.out/'closed.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
    assert result['passed']
if __name__=='__main__':main()
