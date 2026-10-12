#!/usr/bin/env python3
"""Export the source-matched SRT/V-clear PC derivative; no timing acceptance."""
import argparse
import json
import os
from pathlib import Path
import subprocess

import freeze_payload_current_rk_candidate as parent_flow
import build_rem_split_soc as native
from freeze_rk_candidate import (directory, frozen_path, overlaps, publish_new,
    sha256, snapshot, unchanged, write_new)

base = parent_flow.base
require = parent_flow.require
REPO = parent_flow.REPO
FLAG = native.recipe.srt.FLAG
PARENT = '1f78fbf6d9384f8e79a558f25d6e2b9a2b3e3a7a286fd8100f3f8764daca87f2'


def hardware_profile(parent, definitions):
    require(len(definitions) == len(set(definitions)) == 156 and FLAG in definitions, 'native profile drift')
    prior_native = [d for d in definitions if d != FLAG]
    require(len(parent) == 157 and parent[153] == parent_flow.recipe.payload.FLAG, 'wrong parent order')
    require(parent_flow.hardware_profile(parent[:153]+parent[154:], prior_native) == parent, 'parent mode drift')
    result = parent[:-3]+[FLAG]+parent[-3:]
    require(len(result) == len(set(result)) == 158 and result[154] == FLAG, 'wrong hardware extension')
    require(set(result)-{'SYNTHESIS','VTM_NO_DPI'} == set(definitions), 'hardware/simulation mismatch')
    return result


def freeze(parent, sim, out):
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    require(Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev, 'wrong scratch')
    require(out.is_relative_to(scratch) and out != scratch and not out.exists(), 'not fresh external output')
    require(not any(overlaps(out,p) for p in (parent,sim,REPO)), 'overlapping output')
    observed, aliases = {}, {}
    def read(path, digest=None, size=None):
        actual = path.resolve(strict=True); aliases[path] = actual
        return base.read_observed(observed,actual,digest,size)
    def js(path,digest=None): return json.loads(read(path,digest)['data'])
    old = js(parent/'input-manifest.json',PARENT)
    require(old['variant'] == 'payload_current_timing' and old['qualification'] == 'UNQUALIFIED'
            and old['core_mhz'] == 40 and old['write_slots'] == 16 and old['l2_sets'] == 1024
            and len(old['files']) == 190, 'wrong hardware parent')
    started, closed = js(sim/'build-started.json'), js(sim/'build-closed.json')
    require(closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged'], 'PC not compiled')
    require(started['changes'] == native.recipe.TARGETS and started['added_defines'] == [FLAG]
            and started['directed_model'] == native.CORE_MODEL, 'wrong tested core')
    model = closed['binary_sha256']
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted',model)
    for p,h in started['pins'].items(): read(Path(p),h)
    definitions = read(sim/'defines.txt')['data'].decode().splitlines()
    hw = hardware_profile(old['hardware_defines'],definitions)
    require(read(parent/'defines.txt')['data'] == ('\n'.join(old['hardware_defines'])+'\n').encode(), 'parent define drift')
    actual = [s[2:] for s in started['command'] if s.startswith('-D')]+[s[8:] for s in started['command'] if s.startswith('+define+')]
    require(len(actual) == len(definitions) and set(actual) == set(definitions), 'command profile drift')
    require('-GBOARD_POSTED=1' in started['command'] and '-GBOARD_WRITE_SLOTS=16' in started['command'], 'transport drift')
    base.check_native_command(read(sim/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat')['data'].decode(),started['command'])
    expected = native.recipe.srt.transform({n: read(parent/'ventium'/n)['data'].decode() for n in native.recipe.srt.HASHES})
    expected['rtl/core/core.sv'] = native.recipe.clear.transform(read(parent/'ventium/rtl/core/core.sv')['data'].decode())
    payload, rows, changed, compiled = {}, [], [], 0
    for row in old['files']:
        name = frozen_path(row['frozen']); require(name not in payload,'duplicate input')
        prior = read(parent/name,row['sha256'],row['bytes'])
        data, source = prior['data'], parent/name
        if name.startswith('ventium/') and Path(name).suffix in base.SUFFIXES:
            source = sim/'source'/name.removeprefix('ventium/')
            require(str(source) in started['pins'],'not a compiled input: '+name)
            data = read(source,started['pins'][str(source)])['data']
            if name == base.SYSTEM: data = base.projection(prior['data'],data)
            else: compiled += 1
        if sha256(data) != prior['sha256']:
            relative = name.removeprefix('ventium/')
            require(relative in expected and data == expected[relative].encode(),'unreviewed change: '+name)
            changed.append(name)
        payload[name] = dict(data=data)
        rows.append(dict(frozen=name,source=str(source),sha256=sha256(data),bytes=len(data),parent_sha256=prior['sha256']))
    require(sorted(changed) == ['ventium/'+n for n in native.recipe.TARGETS] and compiled == 170,'incomplete source match')
    require(base.source_closure(payload) == old['source_closure'] == dict(filelist_units=117,include_edges=49),'filelist drift')
    checker = REPO/'fpga/test_rem_split_rk_wrapper.tcl'
    for p in (Path(__file__),Path(parent_flow.__file__),Path(native.__file__),Path(native.recipe.srt.__file__),
              Path(native.recipe.clear.__file__),checker,REPO/'fpga/test_code_payload_rk_wrapper.tcl'): read(p)
    def stable():
        for p,info in observed.items(): unchanged(p,info)
        require(all(p.resolve(strict=True) == q for p,q in aliases.items()),'input alias changed')
    stable(); out.mkdir(); identity = directory(out)
    for name,item in payload.items(): write_new(out/name,item['data'])
    write_new(out/'defines.txt',('\n'.join(hw)+'\n').encode())
    cmd = ['tclsh',str(checker),str(out/'ventium/fpga/create_project_3mhz_wrapper.tcl'),str(out/'flow'),
           str(out/'defines.txt'),str(out/'ventium'),str(out/'template'),'logic_only']
    done = subprocess.run(cmd,capture_output=True,text=True,timeout=15)
    write_new(out/'source-contract.log',(done.stdout+done.stderr).encode())
    require(done.returncode == 0 and 'exact158defs' in done.stdout and 'POSTED-DDR-SOURCE-CONTRACT-OK' in done.stdout,
            'Tcl contract failed: '+done.stdout+done.stderr)
    stable(); require(directory(out) == identity,'output changed')
    for row in rows: snapshot(out/row['frozen'],row['sha256'],row['bytes'])
    manifest = dict(schema=1,qualification='UNQUALIFIED',variant='rem_split_timing',core_mhz=40,write_slots=16,l2_sets=1024,
        hardware_defines=hw,simulator_defines=156,hardware_additions=['SYNTHESIS','VTM_NO_DPI'],
        parent_manifest_sha256=PARENT,simulator_sha256=model,changed_parent_payloads=changed,
        added_payloads=[],changed_flow_payloads=[],source_closure=old['source_closure'],files=rows,
        source_contract_synthesis_profile='logic_only',canonical_gate_passed=started['canonical_gate_passed'],
        standard_suite=False,hardware_acceptance=False,note='Three-file SRT/V-clear derivative; no timing or board pass inherited.')
    publish_new(out/'input-manifest.json',(json.dumps(manifest,indent=2)+'\n').encode())
    receipt = dict(qualification='UNQUALIFIED',source_contract_passed=True,manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),
        input_pins={str(p):info['sha256'] for p,info in observed.items()},input_aliases={str(p):str(q) for p,q in aliases.items()},payloads=len(rows))
    publish_new(out/'freeze-receipt.json',(json.dumps(receipt,indent=2)+'\n').encode())
    return {k:receipt[k] for k in ('qualification','source_contract_passed','manifest_sha256','payloads')}


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','sim','out'): ap.add_argument('--'+name,type=Path,required=True)
    args = ap.parse_args()
    print(json.dumps(freeze(args.parent.resolve(strict=True),args.sim.resolve(strict=True),args.out.resolve())))
