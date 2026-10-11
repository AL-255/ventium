#!/usr/bin/env python3
"""Combine the independently checked address, tag and SRT timing changes.

This creates a private diagnostic model, not an accepted processor release.
The original failing canonical gate remains visible; no defines or clock-cycle
behavior may be traded away to obtain a timing result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/srt'))
from prepare_mc_address_payload import transform as address
from prepare_parallel_tag_lookup import transform as tags
from prepare_rem_clz_tree import transform as clz
from prepare_qacc_idle_payload import transform as idle

DELTAS = {
    'rtl/core/core_mem_chain.svh': ('mc', address, '5d2044b045cf9fd99281ce4f246d79031e3460bc4017acc43a87515938fd0b37'),
    'rtl/mem/ven_l1d.sv': ('tags', tags, '61161ec0f9231f3c6c714f66552828381192cb29191f6984368447bca744143e'),
    'rtl/fpu/fpu_srt_div.sv': ('qacc', lambda text: idle(clz(text)), 'f9ce70532446bbc7b991180a030bb319d50ba88a93deead1030ba3a73296461f'),
}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def prepare(sources):
    result = {name: fn(sources[name]) for name, (_, fn, _) in DELTAS.items()}
    for name, text in result.items():
        assert hashlib.sha256(text.encode()).hexdigest() == DELTAS[name][2]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'mc', 'tags', 'qacc', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    parent = args.parent.resolve(strict=True)
    roots = {name: getattr(args, name).resolve(strict=True) for name in ('mc','tags','qacc')}
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 5*1024**3
    subprocess.run([str(REPO/'tools/build_scope.sh'), '--is-active'], pass_fds=(9,), check=True)
    old, built = load(parent/'build-started.json'), load(parent/'build-closed.json')
    expected = '1bfb1bb2f6179ba13384cfdd3f4ded7ac5742108ef21add23e6da1f301286e8c'
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == expected
    pins = old['pins'].copy()
    provenance = {}
    relative = sorted(str(p.relative_to(parent/'candidate')) for p in (parent/'candidate').rglob('*') if p.is_file())
    replacements = prepare({name: (parent/'candidate'/name).read_text() for name in DELTAS})
    for name, (label, _, digest) in DELTAS.items():
        source = roots[label]/'core-r1/candidate'
        assert sorted(str(p.relative_to(source)) for p in source.rglob('*') if p.is_file()) == relative
        actual = [p for p in relative if sha(source/p) != sha(parent/'candidate'/p)]
        assert actual == [name], (label, actual)
        assert sha(source/name) == digest and (source/name).read_text() == replacements[name]
        audit_path = roots[label]/({'mc':'core-audit-r2.json','tags':'core-audit.json','qacc':'audit.json'}[label])
        audit = load(audit_path)
        assert audit['audit_complete'] and audit['all_20_canonical_cycle_streams_identical']
        assert not audit['canonical_gate_passed'], 're-review provenance if canonical status changes'
        if label == 'qacc':
            assert audit['counts']['cases'] == 156 and audit['focused_fault_cases'] == 16
        else:
            assert audit['directed_regressions_passed']
            assert sum(r['fixtures'] for r in audit['counts'].values()) == 820
        assert sha(roots[label]/'core-r1/obj/tb_ventium') == audit['model_sha256']
        pins.update(audit['pins'])
        pins[str(audit_path)] = sha(audit_path)
        provenance[label] = dict(audit=str(audit_path), sha256=sha(audit_path), model=audit['model_sha256'])
    assert all(sha(p) == h for p, h in pins.items())
    root.mkdir()
    shutil.copytree(parent/'candidate', root/'candidate')
    for name, text in replacements.items():
        (root/'candidate'/name).write_text(text)
    changes = sorted(p for p in relative if sha(root/'candidate'/p) != sha(parent/'candidate'/p))
    assert changes == sorted(DELTAS)
    oldhost = Path(old['host'])
    host = root/('tb_timing_combo_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(oldhost, host)
    command = [s.replace(str(parent/'candidate'),str(root/'candidate'))
        .replace(str(parent/'obj'),str(root/'obj')).replace(str(oldhost),str(host)) for s in old['command']]
    for p in (Path(__file__), parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium', host,
              REPO/'verif/l1/prepare_mc_address_payload.py', REPO/'verif/l1/prepare_parallel_tag_lookup.py',
              REPO/'verif/srt/prepare_rem_clz_tree.py', REPO/'verif/srt/prepare_qacc_idle_payload.py'):
        pins[str(p)] = sha(p)
    pins.update({str(root/'candidate'/p):sha(root/'candidate'/p) for p in relative})
    def save(name, value):
        with (root/name).open('x') as stream:
            json.dump(value, stream, indent=2)
    save('build-started.json',dict(command=command,pins=pins,host=str(host),parent_model=expected,
        changes=changes,components=provenance,affinity=sorted(os.sched_getaffinity(0)),
        invocation=os.environ['INVOCATION_ID'],canonical_gate_passed=False,gameplay_ipc=None))
    result = dict(passed=False, errors=[], canonical_gate_passed=False, gameplay_ipc=None, standard_suite=False)
    begin = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            native = subprocess.run(command,env={**os.environ,'CCACHE_DISABLE':'1'},stdout=stream,
                stderr=subprocess.STDOUT,pass_fds=(9,),timeout=600)
        result['native_exit'] = native.returncode
        assert native.returncode == 0
        obj = root/'obj'
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                   if Path(s).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True,binary_sha256=sha(obj/'tb_ventium'),private_header=str(header))
    except Exception as error:
        import traceback
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save('build-closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
