"""Check the data-size cofactor with exact source leaves and negative controls."""
import argparse
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time

import prepare_data_size as recipe
from run_leaf import sha

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'out'):
        ap.add_argument('--'+name, type=Path, required=True)
    args = ap.parse_args()
    parent, root = args.parent.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert os.sched_getaffinity(0) == set(range(8,16))
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode == 1
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'], check=True, timeout=10)
    resource.setrlimit(resource.RLIMIT_CORE, (0,0))
    original = (parent/'candidate'/recipe.FILE).read_text()
    candidate = recipe.transform(original)
    started = json.loads((parent/'build-started.json').read_text())
    definitions = started['definitions']
    assert len(definitions) == len(set(definitions)) == 152
    enum = original.split('typedef enum logic [6:0] {',1)[1].split('} state_e;',1)[0]
    replacements = {
        '/* ENUM */': 'typedef enum logic [6:0] {'+enum+'} state_e;',
        '/* CLASSIFICATION */': recipe.classification(candidate),
        '/* FUNCTION */': recipe.extent_function(candidate),
        '/* TAP */': recipe.TAP,
        '/* ORIGINAL_FETCH_SIZE */': recipe.FETCH_SIZE.replace('cur_size', 'original_size'),
    }
    tb = (HERE/'tb_data_size.sv').read_text()
    for before, after in replacements.items():
        assert tb.count(before) == 1
        tb = tb.replace(before,after)
    variants = [('positive',tb),
        ('data-width-lost',tb.replace('cur_data_size = cur_size;', "cur_data_size = 4'd4;")),
        ('fetch-bus-width-lost',tb.replace("cur_size = {1'b0,sfetch_demand_size};", "cur_size = 4'd0;")),
        ('object-override-lost',tb.replace('assign new_count = seg_ext_ovr_v ? seg_ext_ovr :', 'assign new_count ='))]
    assert len({text for _,text in variants}) == 4
    pins = {str(p):sha(p) for p in (Path(__file__),Path(recipe.__file__),HERE/'run_leaf.py',
        HERE/'test_data_size.py', HERE/'tb_data_size.sv', parent/'candidate'/recipe.FILE,
        parent/'build-started.json', REPO/'tools/build_scope.sh', REPO/'tools/verilator_serial.sh',
        Path(os.environ['VENTIUM_VERILATOR_BIN']), Path('/usr/bin/z3'))}
    root.mkdir()
    def write(path,text):
        with path.open('x') as stream: stream.write(text)
        pins[str(path)] = sha(path)
    def save(name,obj):
        with (root/name).open('x') as stream: json.dump(obj,stream,indent=2)
    out_source = root/'candidate'/recipe.FILE
    out_source.parent.mkdir(parents=True)
    write(out_source,candidate)
    save('started.json',dict(pins=pins,definitions=definitions,invocation=os.environ['INVOCATION_ID']))
    rows=[]; queries=[]; begin=time.monotonic()
    result=dict(passed=False,errors=[],whole_core=False,fmax_mhz=None,hardware_acceptance=False,
                standard_suite=False,gameplay_ipc=None)
    try:
        for name,text,expected in [
            ('data-owner-equivalence',recipe.symbolic(),'unsat'),
            ('fetch-exclusion-required',recipe.symbolic().replace('(assert (=> fetch (not data_owner)))',''),'sat')]:
            path=root/(name+'.smt2'); write(path,text)
            native=subprocess.run(['/usr/bin/z3',path],capture_output=True,text=True,timeout=20)
            write(root/(name+'.log'),native.stdout+native.stderr)
            assert native.returncode==0 and not native.stderr and native.stdout.strip()==expected
            queries.append(dict(name=name,result=expected))
        for name,text in variants:
            folder=root/name; folder.mkdir(); code=folder/'miter.sv'; write(code,text)
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv','-j','32',
                '-Wall','-Wno-UNUSED','-Wno-fatal',*['-Werror-'+w for w in
                ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+d for d in definitions], '--top-module','tb_data_size',
                '--Mdir',folder/'obj','-o','test',code]
            row=dict(name=name,command=list(map(str,command))); rows.append(row)
            with (folder/'build.log').open('x') as stream:
                native=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=120)
            row['build_exit']=native.returncode; assert native.returncode==0
            with (folder/'run.log').open('x') as stream:
                native=subprocess.run([folder/'obj/test'],stdout=stream,stderr=subprocess.STDOUT,timeout=60)
            row['native_exit']=native.returncode; log=(folder/'run.log').read_text(); row['log']=log
            if name=='positive': assert native.returncode==0 and 'DATA-SIZE-OK checks=362144 ' in log
            else: assert native.returncode in (-6,1,134) and 'DATA-SIZE-MISMATCH' in log
            row['artifacts']={str(p):sha(p) for p in (code,folder/'build.log',folder/'run.log',folder/'obj/test')}
        result['passed']=True
    except Exception as error:
        result['errors'].append(repr(error))
    result.update(seconds=time.monotonic()-begin,rows=rows,queries=queries,pins=pins,
        pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')},indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__':
    raise SystemExit(main())
