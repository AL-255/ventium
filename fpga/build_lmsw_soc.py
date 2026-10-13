"""Transfer the isolated LMSW repair to the matched UV-fast full-PC model.

Only the five directed-tested files change; retain all shared RTL, defines,
posted transport and native build guards. Canonical/fault gates remain red.
This diagnostic build is not promotion, synthesis or physical acceptance.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_payload_current_soc as base

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/sys/lmsw'))
import prepare_lmsw as recipe

sha, load, save, stable = base.sha, base.load, base.save, base.stable
PARENT_MODEL = 'd8f72e2ca622b46c1ee8b0ec92197d4a6b9cd682411ed91c09ecb5488e7c052c'
CORE_MODEL = 'fddb1fd3f7b677c44ddcc320808a9b756e45adc38718ff4d08b1dedb94d6b52b'
AUDIT = 'fd3e80dab02e36d857ba8601db19bd44df05850310fa422d22b05671117134eb'
BUILDER = '9951c6768f0441d63a0dec66ad6b302afb019924fce529c9d034b1e41c01c8a3'
CHANGES = sorted('rtl/core/'+name for name in recipe.PARENTS)


def prepare(parent, core, proof, root):
    assert not root.exists() and sha(base.__file__)==BUILDER and sha(proof)==AUDIT
    checked = load(proof)
    assert checked['audit_passed'] and checked['model']==CORE_MODEL
    assert checked['changed_files']==CHANGES
    assert (checked['directed_rtl_self_check_cases'],checked['directed_qemu_differential_passes'])==(92,76)
    assert checked['oracle_disagreement_cases']==16 and not checked['fault_differential_gate_passed']
    assert not checked['canonical_gate_passed'] and not checked['standard_suite'] and not checked['hardware_acceptance']
    assert checked['canonical_cycle_traces_identical']==20
    assert (checked['canonical_replay_cases'],checked['canonical_replay_records'])==(108,80800)
    pins = dict(checked['pins']); pins[str(proof)]=sha(proof)
    assert stable(pins)
    old, closed = load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged']
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']==PARENT_MODEL
    before, built = load(core/'build-started.json'),load(core/'build-closed.json')
    assert built['passed'] and built['native_exit']==0 and built['pins_unchanged']
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']==CORE_MODEL and before['changes']==CHANGES
    assert stable(before['pins'])
    source = parent/'source'; files = sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p)==old['pins'][str(p)] for p in files)
    shared = [str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl','fp_shared')
              and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared)==102 and [p for p in shared if sha(source/p)!=sha(core/'candidate'/p)]==CHANGES
    for name in CHANGES:
        assert recipe.transform((source/name).read_text(),Path(name).name)==(core/'candidate'/name).read_text()
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1
    root.mkdir(); shutil.copytree(source,root/'source')
    for name in CHANGES: shutil.copyfile(core/'candidate'/name,root/'source'/name)
    assert all(sha(root/'source'/name)==sha(core/'candidate'/name) for name in shared)
    host = root/'source/ao486-sim/ven'/('sim_lmsw_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0],host)
    command = [s.replace(str(parent),str(root)) for s in old['command']]
    command = [str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]
    assert command[:2]==[str(REPO/'tools/build_scope.sh'),'--'] and '600s' in command
    defs = [s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs)==len(set(defs))==156 and set(defs)==set((parent/'defines.txt').read_text().splitlines())
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dependency = parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dependency.read_text().replace('\\\n',' ').split()[1:]:
        path=Path(name)
        if path.is_absolute(): pins[str(path)]=sha(path)
    for path in (*files, *(p for p in (root/'source').rglob('*') if p.is_file()), Path(__file__),
                 Path(recipe.__file__), Path(base.__file__), Path(base.common.__file__), root/'defines.txt',
                 parent/'build-started.json', parent/'build-closed.json', parent/'build.log',
                 core/'build-started.json', core/'build-closed.json', core/'verify-closed.json', core/'obj/tb_ventium'):
        pins[str(path)]=sha(path)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,changes=CHANGES,added_defines=[],
        parent=str(parent),directed_core=str(core),host=str(host),intersecting_rtl_sources=shared,
        parent_model=PARENT_MODEL,directed_model=CORE_MODEL,proof=str(proof),
        canonical_gate_passed=False,fault_differential_gate_passed=False,qualification='UNQUALIFIED'))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('prepare','build'))
    for name in ('parent','core','proof'): parser.add_argument('--'+name,type=Path)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args(); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3 and sha(base.__file__)==BUILDER
    if args.action=='prepare':
        assert args.parent and args.core and args.proof
        prepare(*(getattr(args,n).resolve(strict=True) for n in ('parent','core','proof')),root)
        print('Prepared exact five-file LMSW full-PC transfer; compiler not started.',flush=True)
        return 0
    return base.build(root)


if __name__=='__main__': raise SystemExit(main())
