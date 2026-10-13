"""Transfer the qualified core's four-file delta to the matched full PC.

Prepare immutable sources, then reuse the bounded native PC builder verbatim.
Canonical failures and structural platform debt remain explicit. Compilation
and timing-experiment admission are not full-PC or physical acceptance.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil

import build_payload_current_soc as base
import endpoint_map_transfer as recipe

sha,load,save,stable = base.sha,base.load,base.save,base.stable
PARENT_MODEL = '693d73f5feed438c834bf09af34b72087309511b3d1cee65a20971cba2216e64'
CORE_MODEL = '164e17003b2ec03cd7b92cc8bbe89b576e5f440becc4204e37368e075c87e8df'
AUDIT = '0165e78d169a5a582fc1878ee0b97b414b40900000f2ab32b3e7e5adff70f5b5'
BUILDER = '9951c6768f0441d63a0dec66ad6b302afb019924fce529c9d034b1e41c01c8a3'
CHANGES = sorted(recipe.PARENTS)


def admit(core, path):
    assert sha(path)==AUDIT
    checked=load(path)
    assert checked['audit_passed'] and checked['model']==CORE_MODEL
    assert checked['changed_files']==[recipe.endpoint.FILE]
    assert (checked['exact_parent_cases'],checked['exact_parent_records'])==(193,22891)
    assert (checked['qemu_differential_cases'],checked['intel_spec_only_cases'])==(173,20)
    assert not checked['complete_fault_differential_gate_passed']
    assert not checked['canonical_gate_passed'] and checked['canonical_native_exit']==2
    assert (checked['canonical_same_input_cases'],checked['canonical_same_input_records'])==(108,80800)
    assert checked['canonical_cycle_traces']==20
    assert not checked['standard_suite'] and not checked['hardware_acceptance']
    assert checked['gameplay_ipc'] is None and checked['fmax_mhz'] is None
    assert stable(checked['pins']) and sha(core/'obj/tb_ventium')==CORE_MODEL
    return dict(checked['pins'],**{str(path):sha(path)})


def prepare(parent,core,proof,root):
    assert not root.exists() and sha(base.__file__)==BUILDER
    pins=admit(core,proof)
    old,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged']
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']==PARENT_MODEL
    before,built=load(core/'build-started.json'),load(core/'build-closed.json')
    assert built['passed'] and built['native_exit']==0 and built['pins_unchanged']
    assert built['binary_sha256']==CORE_MODEL and before['changes']==[recipe.endpoint.FILE]
    assert stable(before['pins'])
    verified=load(core/'verify-closed.json')
    assert verified['pins_unchanged'] and verified['canonical_gate_native_exit']==2
    assert len(verified['deltas'])==20 and all(r['same_records'] for r in verified['deltas'])
    assert not verified['masks_or_goldens_or_bands_changed']
    source=parent/'source'; files=sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p)==old['pins'][str(p)] for p in files)
    for name in CHANGES:
        assert recipe.transform((source/name).read_text(),name)==(core/'candidate'/name).read_text()
    shared=[str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl','fp_shared')
            and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared)==102 and [p for p in shared if sha(source/p)!=sha(core/'candidate'/p)]==CHANGES
    hosts=[Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1
    root.mkdir(); shutil.copytree(source,root/'source')
    for name in CHANGES: shutil.copyfile(core/'candidate'/name,root/'source'/name)
    assert all(sha(root/'source'/name)==sha(core/'candidate'/name) for name in shared)
    host=root/'source/ao486-sim/ven'/('sim_endpoint_map_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0],host)
    command=[s.replace(str(parent),str(root)) for s in old['command']]
    command=[str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    # Retain the existing in-scope 10/2 GiB limiter, timeout and native args.
    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]
    assert command[:2]==[str(base.REPO/'tools/build_scope.sh'),'--'] and '600s' in command
    defs=[s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs)==len(set(defs))==156 and set(defs)==set((parent/'defines.txt').read_text().splitlines())
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dependency=parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dependency.read_text().replace('\\\n',' ').split()[1:]:
        path=Path(name)
        if path.is_absolute(): pins[str(path)]=sha(path)
    for p in (*files,*(p for p in (root/'source').rglob('*') if p.is_file()),Path(__file__),
              Path(recipe.__file__),Path(recipe.endpoint.__file__),Path(recipe.smsw.__file__),
              Path(base.__file__),Path(base.common.__file__),root/'defines.txt',
              parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
              core/'build-started.json',core/'build-closed.json',core/'verify-closed.json',core/'obj/tb_ventium'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,changes=CHANGES,added_defines=[],
        parent=str(parent),directed_core=str(core),host=str(host),intersecting_rtl_sources=shared,
        parent_model=PARENT_MODEL,directed_model=CORE_MODEL,proof=str(proof),
        canonical_gate_passed=False,qualification='UNQUALIFIED'))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    for name in ('parent','core','proof'): ap.add_argument('--'+name,type=Path)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args(); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and scratch.stat().st_dev!=base.REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3 and sha(base.__file__)==BUILDER
    if args.action=='prepare':
        assert args.parent and args.core and args.proof
        prepare(*(getattr(args,n).resolve(strict=True) for n in ('parent','core','proof')),root)
        print('Prepared exact four-file endpoint/SMSW PC transfer; compiler not started.',flush=True)
        return 0
    # The inherited command owns the build scope. Do not wrap this twice.
    return base.build(root)


if __name__=='__main__': raise SystemExit(main())
