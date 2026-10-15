"""Full-output actual-decoder miter under the normal bounded build scope.

Private candidate only. No root RTL write, full-core or FPGA acceptance claim.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import time

import prepare_prefix_opcode as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
PACKAGES = ('rtl/ventium_pkg.sv', 'rtl/core/ventium_alu_pkg.sv',
            'rtl/core/ventium_decode_pkg.sv', 'rtl/fpu/fpu_x87_pkg.sv',
            'rtl/core/ventium_x87_pkg.sv', 'rtl/core/ventium_sys_pkg.sv')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fixture(source):
    header = source[:source.index('\n);')]
    ports = re.findall(r'^\s*(input|output)\s+(.+?)\s+(\w+)(\s*\[[^\]]+\])?\s*,?\s*(?://.*)?$',
                       header, re.M)
    if len(ports) != len(re.findall(r'^\s*(?:input|output)\s+', header, re.M)):
        raise ValueError('port parser omitted a port')
    assert len({p[2] for p in ports}) == len(ports)
    imports = header[header.index('  import '):header.index('\n(')]
    out = ['module tb_prefix_opcode;', imports]
    for direction, kind, name, array in ports:
        for prefix in ('',) if direction == 'input' else ('p_', 'f_', 'b_', 's_'):
            out.append(f'  {kind} {prefix}{name}{array};')
    for version, prefix in (('parent','p_'), ('fixed','f_'), ('bad_end','b_'), ('bad_second','s_')):
        connections = [f'.{name}({"" if direction=="input" else prefix}{name})'
                       for direction, _, name, _ in ports]
        out.append(f'decode_stages_{version} {version}(\n' + ',\n'.join(connections) + ');')
    out.append('task automatic check_outputs();')
    for direction, _, name, _ in ports:
        if direction == 'output':
            out.append(f'  if (p_{name} !== ((mutant==1)?b_{name}:((mutant==2)?s_{name}:f_{name}))) '
                       f'$fatal(1,"PREFIX-OPCODE-MISMATCH {name} checks=%0d mutant=%0d valid=%0d",'
                       'checks,mutant,ibuf_valid);')
    out += ['endtask', '`include "tb_prefix_opcode_body.svh"', 'endmodule']
    return '\n'.join(out)+'\n', len([p for p in ports if p[0]=='output'])


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    args=ap.parse_args()
    assert __debug__
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    root=args.out.resolve(); parent=args.parent.resolve(strict=True)
    assert root.is_relative_to(scratch) and not root.exists()
    assert parent.is_relative_to(scratch) and scratch.stat().st_dev != REPO.stat().st_dev
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert os.sched_getaffinity(0)=={14}
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run([REPO/'tools/verilator_serial.sh','--version'],check=True,timeout=10)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    cg=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert int((cg/'memory.max').read_text())<=4*1024**3
    start=time.monotonic()
    def guard():
        assert time.monotonic()-start<580, '580 second leaf deadline'
        assert shutil.disk_usage(scratch).free>4*1024**3, 'external disk reserve'
    guard()
    source=parent/'candidate'
    old=(source/recipe.FILE).read_text(); new=recipe.transform(old)
    tb, output_count=fixture(old)
    definitions=json.loads((parent/'prepared.json').read_text())['definitions']
    assert len(definitions)==len(set(definitions))==152
    spine=(source/'rtl/core/core.sv').read_text()
    enum=re.findall(r'typedef enum logic \[4:0\] \{.*?\} sysop_e;',spine,re.S)
    assert len(enum)==1, 'compilation-unit system opcode type drift'
    pins={str(p):sha(p) for p in [source/p for p in (*PACKAGES,recipe.FILE,'rtl/core/core.sv')]+[
        parent/'prepared.json',Path(__file__),Path(recipe.__file__),
        HERE/'tb_prefix_opcode_body.svh',HERE/'test_prefix_opcode.py',
        REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',
        Path(os.environ['VENTIUM_VERILATOR_BIN'])]}
    root.mkdir()
    def save(path, text):
        with path.open('x') as f: f.write(text)
        return path
    def generated(name, text):
        path=save(root/name,text); pins[str(path)]=sha(path); return path
    sources=[generated(Path(p).name,(source/p).read_text()) for p in PACKAGES]
    sources.append(generated('sysop_type.sv',enum[0]+'\n'))
    generated('frozen_runner.py',Path(__file__).read_text())
    generated('frozen_recipe.py',Path(recipe.__file__).read_text())
    mutants={
        'bad_end':new.replace('prefix_opcode_end[15] = prefix_contig_mask[14]',
                              "prefix_opcode_end[15] = 1'b0"),
        'bad_second':new.replace('ibuf_known[n+1][bitno]','ibuf_known[n][bitno]')}
    for name, text in {'parent':old,'fixed':new,**mutants}.items():
        assert text != new if name in mutants else True
        sources.append(generated('decode_stages_'+name+'.sv',
                                 text.replace('decode_stages','decode_stages_'+name)))
    generated('decode_stages.sv',new)
    generated('tb_prefix_opcode_body.svh',(HERE/'tb_prefix_opcode_body.svh').read_text())
    sources.append(generated('tb_prefix_opcode.sv',tb))
    result=dict(passed=False,errors=[],native=[],pins=pins,outputs=output_count,
                checks=0,gameplay_ipc=None,fmax_mhz=None,full_core=False,
                standard_suite=False,hardware_acceptance=False,
                scope=os.environ['VENTIUM_BUILD_SCOPE_UNIT'],
                invocation=os.environ.get('INVOCATION_ID'),definitions=definitions)
    save(root/'started.json',json.dumps(result,indent=2)+'\n')
    def native(command, logname, limit):
        guard(); logpath=root/logname; began=time.monotonic()
        with logpath.open('x') as log:
            child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,
                                   pass_fds=(9,),start_new_session=True)
            affinity=sorted(os.sched_getaffinity(child.pid)); assert affinity==[14]
            try:
                while child.poll() is None:
                    guard()
                    if time.monotonic()-began>limit: raise TimeoutError(logname)
                    time.sleep(.2)
                code=child.wait()
            except BaseException:
                os.killpg(child.pid,signal.SIGKILL); child.wait(); raise
        result['native'].append(dict(command=list(map(str,command)),exit=code,
            seconds=time.monotonic()-began,affinity=affinity,log=str(logpath),sha256=sha(logpath)))
        return code,logpath.read_text()
    try:
        cmd=[str(REPO/'tools/verilator_serial.sh'),'--binary','--timing','--assert',
             '-sv','-j','1','--threads','1','-Wall','-Wno-UNUSED','-Wno-fatal',
             *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
             *['+define+'+d for d in definitions],'-I'+str(root),
             '--top-module','tb_prefix_opcode','--Mdir',str(root/'obj'),'-o','test',*map(str,sources)]
        code,_=native(cmd,'build.log',200); assert code==0,'build.log'
        model=root/'obj/test'; result['model_sha256']=sha(model)
        code,log=native([str(model)],'run.log',250)
        assert code==0 and 'PREFIX-OPCODE-OK checks=2752512 mutant=0' in log,'run.log'
        result['checks']=2752512
        for mutant in (1,2):
            code,log=native([str(model),f'+mutant={mutant}'],f'mutant-{mutant}.log',30)
            assert code in (-6,1,134) and 'PREFIX-OPCODE-MISMATCH' in log,log
            assert 'PREFIX-OPCODE-OK' not in log
        result['passed']=True
    except Exception as error:
        result['errors'].append(repr(error))
    result['pins_unchanged']=all(sha(p)==v for p,v in pins.items())
    result['memory_events']=(cg/'memory.events').read_text()
    result['memory_peak']=int((cg/'memory.peak').read_text())
    result['passed'] &= result['pins_unchanged'] and all(int(line.split()[1])==0
        for line in result['memory_events'].splitlines() if line.split()[0].startswith('oom'))
    result['seconds']=time.monotonic()-start
    save(root/'closed.json',json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','definitions','native')},indent=2))
    return int(not result['passed'])


if __name__=='__main__':
    raise SystemExit(main())
