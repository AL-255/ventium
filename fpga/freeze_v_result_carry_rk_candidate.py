"""Freeze the V-result timing cut, retaining the current AUX/mouse RK wrapper.

All compiled platform HDL is checked, not just the changed files. This is an
unqualified source export, never a timing, full-wrapper simulation or board pass.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

import build_v_result_carry_soc as native
import freeze_aux_mouse_rk_candidate as parent_flow
from freeze_rk_candidate import (directory,frozen_path,overlaps,publish_new,
    sha256,snapshot,unchanged,write_new)

base=parent_flow.base
REPO,require=base.REPO,base.require
PARENT='d693f7b45f03baa7cb2d70c15ee162b47bd3e3fc5f8264d348c93bdfdbf4ecb5'
MODEL='b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'
CHANGES=['ventium/'+n for n in native.CHANGES]


def check_profile(old,start,closed,definitions):
    require(old['variant']=='pipe_wait_aux_mouse_unqualified' and old['qualification']=='UNQUALIFIED',
            'wrong hardware parent')
    require(old['core_mhz']==40 and old['write_slots']==16 and old['l2_sets']==1024,'hardware geometry drift')
    require(old['processor_platform_simulator_sha256']==native.PARENT_MODEL,'wrong parent processor')
    require(start['parent_model']==native.PARENT_MODEL and start['directed_model']==native.CORE_MODEL,
            'wrong compiled source closure')
    require(start['changes']==native.CHANGES and start['added_defines']==[],'extra source/define changes')
    require(closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged']
            and closed['binary_sha256']==MODEL,'native PC build not successfully closed')
    native.check_definitions(start['command'],definitions)
    hw=old['hardware_defines']
    require(len(hw)==len(set(hw))==159 and set(hw)-{'SYNTHESIS','VTM_NO_DPI'}==set(definitions),
            'hardware/simulator profile differs')


def check_delta(name,before,after):
    return native.check_delta(name.removeprefix('ventium/'),before,after)


def freeze(parent,sim,build_unit,out):
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    require(__debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
            and scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>4*1024**3,
            'external scratch admission failed')
    require(out!=scratch and out.is_relative_to(scratch) and not out.exists(),'fresh output required')
    require(not any(overlaps(out,p) for p in (parent,sim,REPO)),'overlapping output')
    observed,aliases={},{}
    def read(p,digest=None,size=None):
        actual=p.resolve(strict=True);aliases[p]=actual
        return base.read_observed(observed,actual,digest,size)['data']
    def js(p,digest=None):return json.loads(read(p,digest))
    old=js(parent/'input-manifest.json',PARENT)
    previous=js(parent/'freeze-receipt.json')
    require(previous['manifest_sha256']==PARENT and previous['source_contract_passed'],'unsealed parent')
    for p,h in previous['input_pins'].items():read(Path(p),h)
    require(all(Path(p).resolve(strict=True)==Path(q) for p,q in previous['input_aliases'].items()),'parent alias drift')
    start,closed=js(sim/'build-started.json'),js(sim/'build-closed.json')
    definitions=read(sim/'defines.txt').decode().splitlines()
    check_profile(old,start,closed,definitions)
    owner=parent_flow.closed_owner(build_unit,start['invocation'])
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted',MODEL)
    for p,h in start['pins'].items():read(Path(p),h)
    base.check_native_command(read(sim/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat').decode(),start['command'])
    hw=read(parent/'defines.txt')
    require(hw==('\n'.join(old['hardware_defines'])+'\n').encode(),'define file drift')
    payload,origins,original,changed={},{},{},[];compiled=0
    for row in old['files']:
        name=frozen_path(row['frozen']);require(name not in original,'duplicate payload')
        before=read(parent/name,row['sha256'],row['bytes']);original[name]=data=before;source=parent/name
        if name.startswith('ventium/') and Path(name).suffix in base.SUFFIXES:
            source=sim/'source'/name.removeprefix('ventium/')
            require(str(source) in start['pins'],'source not compiled: '+name)
            data=read(source,start['pins'][str(source)])
            if name==base.SYSTEM:data=base.projection(before,data)
            else:compiled+=1
        if check_delta(name,before,data):changed.append(name)
        payload[name],origins[name]=data,source
    require(sorted(changed)==CHANGES and compiled==170 and len(payload)==192,'incomplete source match')
    require(sha256(payload['ventium/'+native.AUX])==native.AUX_SHA,'AUX ownership fix lost')
    require(base.source_closure({n:dict(data=b) for n,b in payload.items()})==old['source_closure'],
            'filelist/include drift')
    checker=REPO/'fpga/test_aux_mouse_rk_wrapper.tcl'
    for p in (Path(__file__),Path(native.__file__),Path(native.recipe.__file__),Path(parent_flow.__file__),
              Path(base.__file__),checker,REPO/'fpga/test_strict_mf_rk_wrapper.tcl',
              REPO/'fpga/test_rem_split_rk_wrapper.tcl',REPO/'fpga/test_code_payload_rk_wrapper.tcl',
              REPO/'fpga/freeze_rk_candidate.py'):read(p)
    def stable():
        for p,info in observed.items():unchanged(p,info)
        require(all(p.resolve(strict=True)==q for p,q in aliases.items()),'input alias drift')
    stable();out.mkdir();identity=directory(out);rows=[]
    for name,data in payload.items():
        write_new(out/name,data)
        rows.append(dict(frozen=name,source=str(origins[name]),sha256=sha256(data),bytes=len(data),
                         parent_sha256=sha256(original[name])))
    write_new(out/'defines.txt',hw)
    command=['tclsh',str(checker),str(out/'ventium/fpga/create_project_3mhz_wrapper.tcl'),
             str(out/'flow'),str(out/'defines.txt'),str(out/'ventium'),str(out/'template'),'logic_only']
    run=subprocess.run(command,capture_output=True,text=True,timeout=15)
    write_new(out/'source-contract.log',(run.stdout+run.stderr).encode())
    require(run.returncode==0 and 'AUX-MOUSE-PROJECT-SOURCE-CONTRACT-OK: exact159defs' in run.stdout,
            'source contract failed: '+run.stdout+run.stderr)
    stable();require(directory(out)==identity,'output identity changed')
    for row in rows:snapshot(out/row['frozen'],row['sha256'],row['bytes'])
    manifest=dict(old,variant='v_result_carry_aux_mouse_unqualified',files=rows,parent_manifest_sha256=PARENT,
        changed_parent_payloads=CHANGES,changed_flow_payloads=[],added_payloads=[],
        simulator_sha256=None,processor_platform_simulator_sha256=MODEL,full_wrapper_elaborated=False,
        full_soc_lint=False,canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
        fmax_mhz=None,gameplay_ipc=None,
        note='V arithmetic result carry cut; real flag CF, complete processor fixes and AUX/mouse retained. '
             'Complete wrapper not modeled by PC binary. No timing or acceptance inherited.')
    publish_new(out/'input-manifest.json',(json.dumps(manifest,indent=2)+'\n').encode())
    receipt=dict(qualification='UNQUALIFIED',source_contract_passed=True,payloads=len(rows),
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),build_owner=owner,
        input_pins={str(p):info['sha256'] for p,info in observed.items()},
        input_aliases={str(p):str(q) for p,q in aliases.items()},complete_wrapper_or_board_qualified=False)
    publish_new(out/'freeze-receipt.json',(json.dumps(receipt,indent=2)+'\n').encode())
    return {k:receipt[k] for k in ('qualification','source_contract_passed','payloads','manifest_sha256')}


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','sim','out'):ap.add_argument('--'+n,type=Path,required=True)
    ap.add_argument('--build-unit',required=True);a=ap.parse_args()
    print(json.dumps(freeze(a.parent.resolve(strict=True),a.sim.resolve(strict=True),a.build_unit,a.out.resolve())))
