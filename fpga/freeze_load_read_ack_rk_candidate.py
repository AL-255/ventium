#!/usr/bin/env python3
"""Freeze the source-matched single-file load-ACK PC delta for timing analysis."""
import argparse
import json
import os
from pathlib import Path
import subprocess

import freeze_rem_split_rk_candidate as previous
import build_load_read_ack_soc as native
from freeze_rk_candidate import (directory,frozen_path,overlaps,publish_new,
    sha256,snapshot,unchanged,write_new)

base, require, REPO = previous.base, previous.require, previous.REPO
PARENT = '4329eff21cca7394e53cba00944ac165bd95b7d52fff35bdad76acc4d89d2d79'


def freeze(parent,sim,out):
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    require(Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev,'wrong scratch')
    require(out.is_relative_to(scratch) and out!=scratch and not out.exists(),'not fresh external output')
    require(not any(overlaps(out,p) for p in (parent,sim,REPO)),'overlapping output')
    observed,aliases={},{}
    def read(p,digest=None,size=None):
        actual=p.resolve(strict=True); aliases[p]=actual
        return base.read_observed(observed,actual,digest,size)
    def js(p,digest=None): return json.loads(read(p,digest)['data'])
    old=js(parent/'input-manifest.json',PARENT)
    require(old['variant']=='rem_split_timing' and old['qualification']=='UNQUALIFIED'
            and old['core_mhz']==40 and old['write_slots']==16 and old['l2_sets']==1024
            and len(old['files'])==190,'wrong parent')
    started,closed=js(sim/'build-started.json'),js(sim/'build-closed.json')
    require(closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged'],'PC not compiled')
    require(started['changes']==[native.recipe.PAYLOAD] and started['added_defines']==[]
            and started['directed_model']==native.CORE_MODEL,'wrong directed core')
    model=closed['binary_sha256']
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted',model)
    for p,h in started['pins'].items(): read(Path(p),h)
    defs=read(sim/'defines.txt')['data'].decode().splitlines()
    hw=old['hardware_defines']
    require(len(defs)==len(set(defs))==156 and len(hw)==len(set(hw))==158,'profile size drift')
    require(set(hw)-{'SYNTHESIS','VTM_NO_DPI'}==set(defs),'simulation/hardware modes differ')
    require(read(parent/'defines.txt')['data']==('\n'.join(hw)+'\n').encode(),'parent define drift')
    actual=[s[2:] for s in started['command'] if s.startswith('-D')]+[s[8:] for s in started['command'] if s.startswith('+define+')]
    require(len(actual)==len(defs) and set(actual)==set(defs),'native profile mismatch')
    require('-GBOARD_POSTED=1' in started['command'] and '-GBOARD_WRITE_SLOTS=16' in started['command'],'transport drift')
    base.check_native_command(read(sim/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat')['data'].decode(),started['command'])
    expected=native.recipe.transform(read(parent/'ventium'/native.recipe.PAYLOAD)['data'].decode()).encode()
    payload,rows,changed,compiled={},[],[],0
    for row in old['files']:
        name=frozen_path(row['frozen']); require(name not in payload,'duplicate input')
        prior=read(parent/name,row['sha256'],row['bytes'])
        data,source=prior['data'],parent/name
        if name.startswith('ventium/') and Path(name).suffix in base.SUFFIXES:
            source=sim/'source'/name.removeprefix('ventium/')
            require(str(source) in started['pins'],'not a compiled input: '+name)
            data=read(source,started['pins'][str(source)])['data']
            if name==base.SYSTEM: data=base.projection(prior['data'],data)
            else: compiled+=1
        if sha256(data)!=prior['sha256']:
            require(name=='ventium/'+native.recipe.PAYLOAD and data==expected,'unreviewed delta: '+name)
            changed.append(name)
        payload[name]=dict(data=data)
        rows.append(dict(frozen=name,source=str(source),sha256=sha256(data),bytes=len(data),parent_sha256=prior['sha256']))
    require(changed==['ventium/'+native.recipe.PAYLOAD] and compiled==170,'incomplete source match')
    require(base.source_closure(payload)==old['source_closure']==dict(filelist_units=117,include_edges=49),'filelist drift')
    checker=REPO/'fpga/test_rem_split_rk_wrapper.tcl'
    for p in (Path(__file__),Path(previous.__file__),Path(native.__file__),Path(native.recipe.__file__),
              checker,REPO/'fpga/test_code_payload_rk_wrapper.tcl'): read(p)
    def stable():
        for p,info in observed.items(): unchanged(p,info)
        require(all(p.resolve(strict=True)==q for p,q in aliases.items()),'input alias changed')
    stable(); out.mkdir(); identity=directory(out)
    for name,item in payload.items(): write_new(out/name,item['data'])
    write_new(out/'defines.txt',('\n'.join(hw)+'\n').encode())
    command=['tclsh',str(checker),str(out/'ventium/fpga/create_project_3mhz_wrapper.tcl'),
             str(out/'flow'),str(out/'defines.txt'),str(out/'ventium'),str(out/'template'),'logic_only']
    done=subprocess.run(command,capture_output=True,text=True,timeout=15)
    write_new(out/'source-contract.log',(done.stdout+done.stderr).encode())
    require(done.returncode==0 and 'exact158defs' in done.stdout and 'POSTED-DDR-SOURCE-CONTRACT-OK' in done.stdout,
            'Tcl contract failed: '+done.stdout+done.stderr)
    stable(); require(directory(out)==identity,'output changed')
    for row in rows: snapshot(out/row['frozen'],row['sha256'],row['bytes'])
    manifest=dict(schema=1,qualification='UNQUALIFIED',variant='load_read_ack_timing',core_mhz=40,write_slots=16,l2_sets=1024,
        hardware_defines=hw,simulator_defines=156,hardware_additions=['SYNTHESIS','VTM_NO_DPI'],
        parent_manifest_sha256=PARENT,simulator_sha256=model,changed_parent_payloads=changed,
        added_payloads=[],changed_flow_payloads=[],source_closure=old['source_closure'],files=rows,
        source_contract_synthesis_profile='logic_only',canonical_gate_passed=started['canonical_gate_passed'],
        standard_suite=False,hardware_acceptance=False,note='Read-only load completion delta; no timing or board pass inherited.')
    publish_new(out/'input-manifest.json',(json.dumps(manifest,indent=2)+'\n').encode())
    receipt=dict(qualification='UNQUALIFIED',source_contract_passed=True,
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),
        input_pins={str(p):v['sha256'] for p,v in observed.items()},input_aliases={str(p):str(q) for p,q in aliases.items()},payloads=len(rows))
    publish_new(out/'freeze-receipt.json',(json.dumps(receipt,indent=2)+'\n').encode())
    return {k:receipt[k] for k in ('qualification','source_contract_passed','manifest_sha256','payloads')}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','sim','out'): parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    print(json.dumps(freeze(args.parent.resolve(strict=True),args.sim.resolve(strict=True),args.out.resolve())))
