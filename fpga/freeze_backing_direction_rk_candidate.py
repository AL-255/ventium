"""Seal early backing direction with the corrected posted-DDR mouse wrapper.

Every common compiled HDL input is checked. A CPU-platform build does not model
the FPGA wrapper and does not qualify timing, full guests or physical hardware.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil

import build_backing_direction_soc as native
import freeze_v_result_carry_rk_candidate as previous
import posted_mouse_evidence as mouse
from freeze_rk_candidate import (directory,frozen_path,overlaps,publish_new,
    sha256,snapshot,unchanged,write_new)

base,parent_flow=previous.base,previous.parent_flow
REPO,require=base.REPO,base.require
PARENT=mouse.MANIFEST
VARIANT='backing_direction_posted_mouse_unqualified'
CHANGES=['ventium/'+n for n in native.CHANGES]


def check_profile(old,start,closed,definitions,model):
    require(re.fullmatch('[0-9a-f]{64}',model),'model hash required')
    require(old['variant']==mouse.VARIANT and old['qualification']=='UNQUALIFIED','wrong hardware parent')
    require(old['core_mhz']==40 and old['write_slots']==16 and old['l2_sets']==1024,'hardware geometry drift')
    require(old['processor_platform_simulator_sha256']==native.PARENT_MODEL,'wrong parent CPU')
    require(start['parent_model']==native.PARENT_MODEL and start['directed_model']==native.CORE_MODEL,'wrong compiled closure')
    require(start['changes']==native.CHANGES and start['added_defines']==[],'extra deltas')
    require(closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged']
            and closed['binary_sha256']==model,'native PC build not closed successfully')
    native.check_definitions(start['command'],definitions)
    hw=old['hardware_defines']
    require(len(hw)==len(set(hw))==159 and set(hw)-{'SYNTHESIS','VTM_NO_DPI'}==set(definitions),'profile mismatch')


def check_delta(name,before,after):
    return native.check_delta(name.removeprefix('ventium/'),before,after)


def freeze(parent,sim,build_unit,model,out):
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
    old=js(parent/'input-manifest.json',PARENT);prior=js(parent/'freeze-receipt.json')
    require(prior['manifest_sha256']==PARENT and prior['preprocessing_passed'],'unsealed parent')
    for p,h in {**prior['input_pins'],**mouse.check(parent)}.items():read(Path(p),h)
    start,closed=js(sim/'build-started.json'),js(sim/'build-closed.json')
    definitions=read(sim/'defines.txt').decode().splitlines()
    check_profile(old,start,closed,definitions,model)
    owner=parent_flow.closed_owner(build_unit,start['invocation'])
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted',model)
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
    require(sha256(payload['ventium/'+native.previous.AUX])==native.previous.AUX_SHA,'AUX fix lost')
    require(sha256(payload[mouse.repair.WRAPPER])==mouse.WRAPPER_SHA,'posted mouse fix lost')
    require(base.source_closure({n:dict(data=b) for n,b in payload.items()})==old['source_closure'],'filelist drift')
    for p in (Path(__file__),Path(native.__file__),Path(native.recipe.__file__),Path(previous.__file__),
              Path(parent_flow.__file__),Path(base.__file__),Path(mouse.__file__),Path(mouse.repair.__file__),
              REPO/'fpga/freeze_rk_candidate.py',Path('/usr/bin/iverilog')):read(p)
    def stable():
        for p,info in observed.items():unchanged(p,info)
        require(all(p.resolve(strict=True)==q for p,q in aliases.items()),'input alias drift')
    stable();out.mkdir();identity=directory(out);rows=[]
    for name,data in payload.items():
        write_new(out/name,data)
        rows.append(dict(frozen=name,source=str(origins[name]),sha256=sha256(data),bytes=len(data),
                         parent_sha256=sha256(original[name])))
    write_new(out/'defines.txt',hw)
    checks=[]
    for label,defs in (('posted_exact159',old['hardware_defines']),
                       ('nonposted_control',[n for n in old['hardware_defines'] if n!='VEN_DDR_POSTED'])):
        text=mouse.repair.preprocess(out/mouse.repair.WRAPPER,defs)
        mouse.repair.check_devices(text)
        write_new(out/(label+'.preprocessed.v'),text.encode())
        checks.append(dict(profile=label,defines=defs,both_devices_present=True,
                           preprocessed_sha256=sha256(text.encode()),elaborated=False))
    stable();require(directory(out)==identity,'output identity changed')
    for row in rows:snapshot(out/row['frozen'],row['sha256'],row['bytes'])
    manifest=dict(old,variant=VARIANT,files=rows,parent_manifest_sha256=PARENT,
        changed_parent_payloads=CHANGES,changed_flow_payloads=[],added_payloads=[],
        simulator_sha256=None,processor_platform_simulator_sha256=model,full_wrapper_elaborated=False,
        full_soc_lint=False,canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
        fmax_mhz=None,gameplay_ipc=None,
        note='Only inactive backing direction changes; all 170 common HDL sources audited. '
             'Retains V-result/AUX and corrected posted mouse wrapper. No timing/guest/hardware acceptance inherited.')
    publish_new(out/'input-manifest.json',(json.dumps(manifest,indent=2)+'\n').encode())
    receipt=dict(qualification='UNQUALIFIED',source_contract_passed=False,preprocessing_passed=True,
        full_wrapper_elaborated=False,payloads=len(rows),compiled_common_hdl=compiled,
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),build_owner=owner,checks=checks,
        input_pins={str(p):info['sha256'] for p,info in observed.items()},
        input_aliases={str(p):str(q) for p,q in aliases.items()},complete_wrapper_or_board_qualified=False)
    publish_new(out/'freeze-receipt.json',(json.dumps(receipt,indent=2)+'\n').encode())
    return {k:receipt[k] for k in ('qualification','payloads','compiled_common_hdl','manifest_sha256')}


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','sim','out'):ap.add_argument('--'+n,type=Path,required=True)
    ap.add_argument('--build-unit',required=True);ap.add_argument('--model-sha256',required=True);a=ap.parse_args()
    print(json.dumps(freeze(a.parent.resolve(strict=True),a.sim.resolve(strict=True),
        a.build_unit,a.model_sha256,a.out.resolve())))
