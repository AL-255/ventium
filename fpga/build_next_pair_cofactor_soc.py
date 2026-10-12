"""Transfer the checked RAW hint/pair cofactor into the unchanged PC platform.

Admission is for timing experiments only. The canonical gate is not waived;
directed coverage does not establish a full standard-suite or physical pass.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil

import build_payload_current_soc as base
import prepare_next_pair_cofactor as recipe

sha,load,save,stable = base.sha,base.load,base.save,base.stable
PARENT_MODEL = '87afedaa869e6d8a86f36e31ea7a880875e096b924389ae78e37e65d018ad466'
CORE_MODEL = '5b8c134e4e3d4c6856025ce37d0abdf1cd3bfc424baaae837fa393130d3a541a'
CHANGES = [recipe.PAYLOAD]
PROBE = base.REPO/'verif/l1/next_pair_overlap_probe.svh'


def transformed(text,name):
    assert name == recipe.PAYLOAD
    return recipe.transform(text) + '\n' + PROBE.read_text()


def regressions(core,proof):
    before,done = load(proof/'started.json'),load(proof/'closed.json')
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert [r['label'] for r in done['rows']] == ['load-store','held','branch','integer','fp','agi','ref','agi-store']
    assert done['probe_runs'] == 4240 and done['request_equivalence_assertion']
    assert done['coverage'] == dict(clocks=21190336,agi=18172,ref=24352,retained=0,
        prime=282808,intent=5616,request=3072,accept=1872,shape_only=1536)
    assert any(str(core/'obj/tb_ventium') in command for _,command,_ in before['commands'])
    pins = dict(before['pins'])
    for row in done['rows']:
        assert row['native_exit'] == 0
        folder = proof/row['label']
        receipt = folder/('result.json' if row['label'] == 'held' else 'closed.json')
        assert sha(receipt) == row['receipt_sha256']
        checked = load(receipt)
        assert checked['passed'] and not checked['errors']
        assert checked['inputs_unchanged' if row['label'] == 'held' else 'pins_unchanged']
        pins[str(receipt)] = sha(receipt)
    for p in (proof/'started.json',proof/'closed.json'): pins[str(p)] = sha(p)
    assert stable(pins)
    return pins,dict(probe_runs=done['probe_runs'],coverage=done['coverage'],
                     full_fp_fault_suite=False,standard_suite=False)


def prepare(parent,core,proof,root):
    assert not root.exists()
    old,closed = load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == closed['binary_sha256'] == PARENT_MODEL
    before,built = load(core/'build-started.json'),load(core/'build-closed.json')
    assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged'] and stable(before['pins'])
    assert sha(core/'obj/tb_ventium') == built['binary_sha256'] == CORE_MODEL and before['changes'] == CHANGES
    verified = load(core/'verify-closed.json')
    assert verified['pins_unchanged'] and verified['canonical_gate_native_exit'] in (0,2)
    assert len(verified['deltas']) == 20 and all(r['same_records'] for r in verified['deltas'])
    assert not verified['masks_or_goldens_or_bands_changed']
    pins,stats = regressions(core,proof)
    source = parent/'source'; files = sorted(p for p in source.rglob('*') if p.is_file())
    assert all(not p.is_symlink() and sha(p) == old['pins'][str(p)] for p in files)
    assert transformed((source/recipe.PAYLOAD).read_text(),recipe.PAYLOAD) == (core/'candidate'/recipe.PAYLOAD).read_text()
    shared = [str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl','fp_shared')
              and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared) == 102 and [p for p in shared if sha(source/p) != sha(core/'candidate'/p)] == CHANGES
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1
    root.mkdir(); shutil.copytree(source,root/'source')
    for name in CHANGES: shutil.copyfile(core/'candidate'/name,root/'source'/name)
    assert all(sha(root/'source'/name) == sha(core/'candidate'/name) for name in shared)
    assert [str(p.relative_to(source)) for p in files if sha(p) != sha(root/'source'/p.relative_to(source))] == CHANGES
    host = root/'source/ao486-sim/ven'/('sim_next_pair_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0],host)
    command = [s.replace(str(parent),str(root)) for s in old['command']]
    command = [str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    defs = [s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs) == len(set(defs)) == 156 and set(defs) == set((parent/'defines.txt').read_text().splitlines())
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dependency = parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dependency.read_text().replace('\\\n',' ').split()[1:]:
        p = Path(name)
        if p.is_absolute(): pins[str(p)] = sha(p)
    for p in (*files,*(p for p in (root/'source').rglob('*') if p.is_file()),Path(__file__),
              Path(recipe.__file__),PROBE,Path(base.__file__),Path(base.common.__file__),root/'defines.txt',
              parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
              core/'build-started.json',core/'build-closed.json',core/'verify-closed.json',core/'obj/tb_ventium'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,changes=CHANGES,added_defines=[],
        parent=str(parent),directed_core=str(core),host=str(host),intersecting_rtl_sources=shared,
        statistics=stats,parent_model=PARENT_MODEL,directed_model=CORE_MODEL,
        canonical_gate_passed=verified['canonical_gate_passed'],qualification='UNQUALIFIED'))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    for k in ('parent','core','proof'): ap.add_argument('--'+k,type=Path)
    ap.add_argument('--out',type=Path,required=True)
    args = ap.parse_args(); root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and scratch.stat().st_dev != base.REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert args.parent and args.core and args.proof
        prepare(*(getattr(args,k).resolve(strict=True) for k in ('parent','core','proof')),root)
        print('NEXT-PAIR-SOC-PREPARED; no compiler launched',flush=True)
        return 0
    return base.build(root)


if __name__ == '__main__': raise SystemExit(main())
