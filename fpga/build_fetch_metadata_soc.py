"""Transfer buffered fetch metadata and both qualified FPREM fixes to full PC.

Audit the complete source intersection, not just the latest one-file change.
Keep the original bounded compiler lifecycle and 156-definition UV-fast profile.
This is not canonical, standard-suite or physical-board acceptance.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_payload_current_soc as base

REPO=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(REPO/'verif/fe_pipe'),str(REPO/'verif/srt')]
import prepare_fetch_metadata_owner as recipe
import prepare_remainder_exact as numeric
import prepare_remainder_exceptions as exceptions

sha,load,save,stable=base.sha,base.load,base.save,base.stable
PARENT_MODEL='5eee4d74d729663ad6af4abaa3f0fdbd5cc59937a36945ca81ff46e33b891ce9'
CORE_MODEL='c4d914831fa7a23171e782bf558466ca31b92f42bee34a9c82b58c485e043f6f'
BUILDER='9951c6768f0441d63a0dec66ad6b302afb019924fce529c9d034b1e41c01c8a3'
CHANGES=sorted([recipe.FILE,*exceptions.PARENTS])
AUDIT='4bc9170becf3b2aa4cd231955ebccabe24ee34fbec70e6bad296d3a98355a786'
FP_AUDIT='875d55ff1026d407e3597a1c66d5a794d1c68f2f367d06db821f8102bbbe2521'


def transform(name,text):
    if name==recipe.FILE:return recipe.transform(text)
    if name=='rtl/fpu/fpu_srt_div.sv':return exceptions.transform(numeric.transform(text),name)
    if name=='fp_shared/ven_fp_top.sv':return exceptions.transform(text,name)
    raise ValueError('unreviewed source delta: '+name)


def prepare(parent,core,proof,root):
    assert not root.exists() and sha(base.__file__)==BUILDER
    assert core==proof/'fetch-metadata-core-r1' and parent==proof/'prefix-payload-soc-r1'
    audit_path=proof/'fetch-metadata-audit.json';assert sha(audit_path)==AUDIT
    audit=load(audit_path)
    assert audit['passed'] and audit['functional_passes']==108
    assert (audit['records'],audit['v_retirements'],audit['identical_cycle_streams'])==(80800,30132,20)
    assert (audit['canonical_pass'],audit['canonical_fail'])==(7,101)
    assert sorted(audit['strict_functional_failures'])==['tx_regform','tx_regform2','tx_stack']
    assert not audit['standard_suite'] and not audit['hardware_acceptance']
    pins=dict(audit['pins']);assert stable(pins)
    fp_audit=proof.parent/'ventium-fprem-sequence.iSZ9BAj4/exception-audit.json'
    assert sha(fp_audit)==FP_AUDIT and load(fp_audit)['passed']
    before,built=load(core/'build-started.json'),load(core/'build-closed.json')
    assert built['passed'] and built['native_exit']==0 and built['pins_unchanged']
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']==CORE_MODEL
    pins.update(before['pins'])
    old,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged']
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']==PARENT_MODEL
    source=parent/'source';files=sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p)==old['pins'][str(p)] for p in files)
    shared=[str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl','fp_shared')
            and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared)==102
    assert [n for n in shared if sha(source/n)!=sha(core/'candidate'/n)]==CHANGES
    for name in CHANGES:assert transform(name,(source/name).read_text())==(core/'candidate'/name).read_text()
    hosts=[Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1 and stable(pins)
    root.mkdir();shutil.copytree(source,root/'source')
    for name in CHANGES:shutil.copyfile(core/'candidate'/name,root/'source'/name)
    assert all(sha(root/'source'/n)==sha(core/'candidate'/n) for n in shared)
    host=root/'source/ao486-sim/ven'/('sim_fetch_metadata_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0],host)
    command=[s.replace(str(parent),str(root)) for s in old['command']]
    command=[str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]
    assert command[:2]==[str(REPO/'tools/build_scope.sh'),'--'] and '600s' in command
    affinity=command.index('taskset');assert command[affinity+1:affinity+3]==['-c','0-9,12-31']
    defs=[s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs)==len(set(defs))==156 and set(defs)==set((parent/'defines.txt').read_text().splitlines())
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    assert "localparam bit AO486_LINE_REPLAY = 1'b0;" in (root/'source/ao486-sim/ven/ven_ao486_shim.sv').read_text()
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dependency=parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dependency.read_text().replace('\\\n',' ').split()[1:]:
        path=Path(name)
        if path.is_absolute():pins[str(path)]=sha(path)
    for path in (*files,*(p for p in (root/'source').rglob('*') if p.is_file()),Path(__file__),
                 Path(recipe.__file__),Path(numeric.__file__),Path(exceptions.__file__),
                 Path(base.__file__),Path(base.common.__file__),root/'defines.txt',audit_path,fp_audit,
                 parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
                 core/'build-started.json',core/'build-closed.json',core/'verify-closed.json',core/'obj/tb_ventium'):
        pins[str(path)]=sha(path)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,changes=CHANGES,added_defines=[],
        parent=str(parent),directed_core=str(core),host=str(host),intersecting_rtl_sources=shared,
        parent_model=PARENT_MODEL,directed_model=CORE_MODEL,functional_corpus_passed=True,
        canonical_gate_passed=False,qualification='UNQUALIFIED',gameplay_ipc=None,
        included_fixes=['buffered fetch metadata','FPREM numeric/subnormal','FPREM operand exceptions']))


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('action',choices=('prepare','build'))
    for n in ('parent','core','proof'):ap.add_argument('--'+n,type=Path)
    ap.add_argument('--out',type=Path,required=True);a=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True);root=a.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3 and sha(base.__file__)==BUILDER
    if a.action=='prepare':
        assert a.parent and a.core and a.proof
        prepare(a.parent.resolve(strict=True),a.core.resolve(strict=True),a.proof.resolve(strict=True),root)
        print('Three-file transfer prepared; no compiler or FPGA acceptance.',flush=True);return 0
    return base.build(root)


if __name__=='__main__':raise SystemExit(main())
