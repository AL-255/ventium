"""Build the exact three-file wide-valid derivative after leaf/formal/cache gates."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

import build_prime_query_payload_core as base
import prepare_fp_high_valid_cofactor as recipe
import run_fp_high_valid_cache as cache_gate

MODEL=cache_gate.MODEL
sha,load,save,stable=base.sha,base.load,base.save,base.stable


def prepare(args,root):
    parent=args.parent.resolve(strict=True); cache=args.cache.resolve(strict=True)
    before,built=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    checked=load(cache/'closed.json')
    assert checked['passed'] and checked['pins_unchanged']
    assert [(r['mutant'],r['build_exit'],r['native_exit']) for r in checked['rows']]==[(False,0,0),(True,0,1)]
    assert checked['rows'][0]['coverage']==[
        'HIGH-WINDOW-PAYLOAD-OK valid=66339 shadow=42254 primary=24085 duplicate=25 blocked=152',
        'PARALLEL-CACHE-MITER checks=737677 next=414']
    pins={**before['pins'],**checked['pins']}
    for row in checked['rows']: pins.update(row['artifacts'])
    source=parent/'candidate'; files=base.common.candidate_files(source)
    assert len(files)==195 and all(sha(p)==before['pins'][str(p)] for p in files)
    changes={p:recipe.transform((source/p).read_text(),p) for p in recipe.PARENTS}
    assert changes['rtl/mem/ven_l1d.sv']==(cache/'positive/ven_l1d.sv').read_text()
    flags=[s for s in before['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and 'VL_J=32' in before['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0])
    assert len(definitions)==len(set(definitions))==152
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_FP_LOAD_EARLY_CMD',
            'VEN_FP_LOAD64','VEN_P54_DUAL_BYTE_LOAD_PAIR','VEN_RAW_V_READ_PRIME'}<=set(definitions)
    assert not {'SYNTHESIS','VTM_NO_DPI'}&set(definitions)
    for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(base.__file__).resolve(),
              Path(base.common.__file__).resolve(),Path(cache_gate.__file__).resolve(),
              cache/'closed.json',parent/'obj/tb_ventium',parent/'build-started.json',parent/'build-closed.json'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    for path,text in changes.items(): (root/'candidate'/path).write_text(text)
    relative=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in base.common.candidate_files(root/'candidate')]==relative
    assert sorted(p for p in relative if sha(source/p)!=sha(root/'candidate'/p))==sorted(recipe.PARENTS)
    host=root/('tb_fp_high_valid_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(before['host'],host)
    command=base.common.relocate(before['command'],parent,root,Path(before['host']),host)
    pins[str(host)]=sha(host)
    pins.update({str(root/'candidate'/p):sha(root/'candidate'/p) for p in relative})
    save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=sorted(changes),compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None))
    print('FP-HIGH-VALID-CORE-PREPARED '+str(root),flush=True)


def build(root):
    before=load(root/'prepared.json')
    assert not (root/'build-started.json').exists()
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT']=='ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    assert re.fullmatch('[0-9a-f]{32}',os.environ.get('INVOCATION_ID',''))
    subprocess.run([base.REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    assert stable(before['pins'])
    parent=Path(before['parent']); old=load(parent/'build-started.json')
    assert before['parent_model']==MODEL and before['changes']==sorted(recipe.PARENTS)
    assert before['command']==base.common.relocate(old['command'],parent,root,Path(old['host']),Path(before['host']))
    subprocess.run([base.REPO/'tools/verilator_serial.sh','--version'],check=True,timeout=10)
    save(root/'build-started.json',dict(before,compiler_started=True,invocation=os.environ['INVOCATION_ID'],
        preparation_sha256=sha(root/'prepared.json'),affinity=sorted(os.sched_getaffinity(0))))
    result=dict(passed=False,errors=[],canonical_gate_passed=False,standard_suite=False,
                hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    begin=time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            native=subprocess.run(before['command'],env=dict(os.environ,CCACHE_DISABLE='1'),
                stdout=stream,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=660)
        result['native_exit']=native.returncode; assert native.returncode==0
        obj,host=root/'obj',Path(before['host'])
        assert (obj/(host.stem+'.o')).is_file()
        headers=[Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                 if Path(s).name=='Vventium_top___024root.h']
        assert len(headers)==1
        header=headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve()==(obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'tb_ventium'),private_header=str(header))
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=stable(before['pins']))
    result['passed'] &= result['pins_unchanged']
    save(root/'build-closed.json',result); print(result,flush=True)
    return 0 if result['passed'] else 1


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    for key in ('parent','cache'): ap.add_argument('--'+key,type=Path)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args(); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch
    assert scratch.stat().st_dev!=base.REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    if args.action=='prepare':
        assert args.parent and args.cache and not root.exists()
        prepare(args,root); return 0
    return build(root)


if __name__=='__main__': raise SystemExit(main())
