#!/usr/bin/env python3
"""Export the exact bus-cancellation candidate with unchanged UV-fast clocks/profile."""
import argparse
import json
from pathlib import Path
import subprocess

from freeze_rk_candidate import (FreezeError, absolute_path, checked_sha, directory,
    frozen_path, overlaps, publish_new, sha256, snapshot, unchanged, unique_json, write_new)
from freeze_performance_rk_candidate import source_closure
from freeze_code_payload_rk_candidate import projection, SYSTEM, SUFFIXES
from freeze_prefix_regonly_rk_candidate import SCRIPT_ALIASES, profile
from test_ic_prefix_board_profile import check_native_command

SCRIPT_ALIASES = SCRIPT_ALIASES + (
    'ventium-fp-exec-cut.MNkzxfBO/system/run_same_profile_fp.py',
    'ventium-fp-exec-cut.MNkzxfBO/agi-r1/run_agi_same_profile.py',
    'ventium-parallel-tags.EjloHRba/audit_closed.py',
    'ventium-u-shift-registers.XRngKRoW/run_queue.py',
    # Existing read-only directed-harness headers, also present in the parent
    # model's dependency file. Admit only these exact external aliases.
    'ventium-private-memcmp-jmp.V2edQ6/constructor_ram_receipt.h',
    'ventium-private-memcmp-jmp.V2edQ6/exception_log_probe.h',
    'ventium-private-reset-edge.LHADfg/reset_edge_receipt.h',
)

PARENT='a36e00e8b30b6cfed198e8522c0baa338b528eb490d01e4d0d183f8ec053935e'
DELTAS={
    'rtl/core/core_bus_driver.svh':'e892403371c601c2e2c2660565fb8d4bf8ed7408efe3c0bf271015da63bf7ba1',
}


def require(ok,message):
    if not ok:raise FreezeError(message)


def resolve_source_input(path,prefix):
    """Admit only reviewed lexical aliases, never arbitrary symlink targets."""
    resolved=path.resolve(strict=True)
    if path!=resolved:
        admitted={prefix/n:prefix.resolve(strict=True)/n for n in SCRIPT_ALIASES}
        require(path in admitted and admitted[path]==resolved,'unexpected source alias: '+str(path))
    return resolved


def check_delta(name,old,new):
    if old!=new:
        require(name in DELTAS and new==DELTAS[name],'unreviewed source delta: '+name)
        return True
    return False


def read_observed(observed,path,digest=None,size=None):
    info=snapshot(path,digest,size)
    # The inherited proof closure contains gigabytes of traces. Keep only
    # hash/size/file identity between reads, not every historical file's bytes.
    # stable() still reopens and hashes every input through unchanged().
    identity={k:v for k,v in info.items() if k!='data'}
    require(path not in observed or identity==observed[path],'input changed: '+str(path))
    observed[path]=identity
    return info


def freeze(args):
    MODEL=checked_sha(args.model_sha256)
    parent,sim,out=map(absolute_path,(args.parent,args.sim,args.out))
    repo=Path(__file__).resolve().parents[1]
    roots={p:directory(p) for p in (parent,sim,out,repo)}
    require(not any(overlaps(out,p) for p in (parent,sim,repo)) and not any(out.iterdir()),'output not fresh/separate')
    observed,aliases={},{}
    def read(p,digest=None,size=None):
        return read_observed(observed,p,digest,size)
    def js(p,digest=None):return json.loads(read(p,digest)['data'],object_pairs_hook=unique_json)
    old=js(parent/'input-manifest.json',PARENT)
    require(old['qualification']=='UNQUALIFIED' and old['variant']=='u_shift_register' and
        old['core_mhz']==40 and old['write_slots']==16 and old['l2_sets']==1024 and len(old['files'])==190,'wrong parent')
    started=js(sim/'build-started.json',checked_sha(args.started_sha256))
    closed=js(sim/'build-closed.json',checked_sha(args.closed_sha256))
    require(closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged'] and
        closed['binary_sha256']==MODEL,'native model not closed/pinned')
    require(started['changes']==sorted(DELTAS) and started['added_defines']==[],'unexpected full-PC delta')
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted',MODEL)
    hw=old['hardware_defines']
    require(read(parent/'defines.txt')['data']==('\n'.join(hw)+'\n').encode(),'hardware define drift')
    native=read(sim/'defines.txt')['data'].decode().splitlines();profile(hw,native)
    actual=[a[2:] for a in started['command'] if a.startswith('-D')]
    actual += [a[8:] for a in started['command'] if a.startswith('+define+')]
    require(len(actual)==len(native) and set(actual)==set(native),'native profile drift')
    require('-GBOARD_POSTED=1' in started['command'] and '-GBOARD_WRITE_SLOTS=16' in started['command'],'transport drift')
    check_native_command(read(sim/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat')['data'].decode(),started['command'])
    prefix=Path('/home/yukidama/external/tmp')
    for name,digest in started['pins'].items():
        p=absolute_path(name); resolved=resolve_source_input(p,prefix)
        if p!=resolved:
            aliases[p]=resolved
        read(resolved,checked_sha(digest))
    payload={};changed=[];compiled=0
    for row in old['files']:
        name=frozen_path(row['frozen']);require(name not in payload,'duplicate payload')
        before=read(parent/name,checked_sha(row['sha256']),row['bytes'])
        data,source=before['data'],parent/name
        provenance='historical_ancestry_only_not_acceptance'
        if name.startswith('ventium/') and Path(name).suffix in SUFFIXES:
            source=sim/'source'/name.removeprefix('ventium/')
            require(str(source) in started['pins'],'not a native input: '+name)
            data=read(source,started['pins'][str(source)])['data'];provenance='native_compiled_source'
            if name==SYSTEM:
                data=projection(before['data'],data);provenance='unchanged_hardware_top_proven_against_simulation'
            else:compiled+=1
        if check_delta(name.removeprefix('ventium/'),before['sha256'],sha256(data)):changed.append(name)
        payload[name]=dict(data=data,source=source,parent=before,provenance=provenance)
    require(sorted(changed)==['ventium/'+n for n in sorted(DELTAS)] and compiled==170,'source closure delta')
    closure=source_closure(payload)
    require(closure==old['source_closure']==dict(filelist_units=117,include_edges=49),'filelist/include drift')
    checker=repo/'fpga/test_code_payload_rk_wrapper.tcl'
    for name in ('freeze_bus_cancel_rk_candidate.py','freeze_rk_candidate.py','freeze_performance_rk_candidate.py',
                 'freeze_code_payload_rk_candidate.py','freeze_prefix_regonly_rk_candidate.py',
                 'freeze_store_admit_rk_candidate.py','test_ic_prefix_board_profile.py','test_code_payload_rk_wrapper.tcl'):
        read(repo/'fpga'/name)
    def stable():
        for p,info in observed.items():unchanged(p,info)
        require(all(p.resolve(strict=True)==q for p,q in aliases.items()),'alias changed')
        require(all(directory(p)==identity for p,identity in roots.items()),'root changed')
    stable();rows=[]
    for name,item in payload.items():
        write_new(out/name,item['data'])
        rows.append(dict(frozen=name,source=str(item['source']),sha256=sha256(item['data']),bytes=len(item['data']),
            parent_sha256=item['parent']['sha256'],provenance=item['provenance']))
    write_new(out/'defines.txt',('\n'.join(hw)+'\n').encode())
    result=subprocess.run(['tclsh',str(checker),str(out/'ventium/fpga/create_project_3mhz_wrapper.tcl'),
        str(out/'flow'),str(out/'defines.txt'),str(out/'ventium'),str(out/'template'),'logic_only'],
        capture_output=True,text=True,timeout=15)
    write_new(out/'source-contract.log',(result.stdout+result.stderr).encode())
    require(result.returncode==0 and 'exact156defs' in result.stdout and 'POSTED-DDR-SOURCE-CONTRACT-OK' in result.stdout,'Tcl contract failed')
    stable()
    for row in rows:snapshot(out/row['frozen'],row['sha256'],row['bytes'])
    manifest=dict(schema=1,qualification='UNQUALIFIED',variant='bus_cancel_payload',core_mhz=40,
        write_slots=16,l2_sets=1024,hardware_defines=hw,simulator_defines=154,
        hardware_additions=['SYNTHESIS','VTM_NO_DPI'],parent_manifest_sha256=PARENT,simulator_sha256=MODEL,
        simulator_started_sha256=args.started_sha256,simulator_closed_sha256=args.closed_sha256,
        changed_parent_payloads=changed,added_payloads=[],changed_flow_payloads=[],source_closure=closure,
        files=rows,source_contract_synthesis_profile='logic_only',
        inherited_simulator_structural_warning_count=closed['structural_debt_count'],
        note='Source only. Canonical differential gate remains FAIL. No suite/gameplay/timing/FPGA pass inherited.')
    publish_new(out/'input-manifest.json',(json.dumps(manifest,indent=2)+'\n').encode())
    receipt=dict(qualification='UNQUALIFIED',source_contract_passed=True,
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),
        input_pins={str(p):i['sha256'] for p,i in observed.items()},
        native_driver_aliases={str(p):str(q) for p,q in aliases.items()},payloads=len(rows),
        hardware_defines=len(hw),native_compiled_nonwrapper_payloads=compiled)
    publish_new(out/'freeze-receipt.json',(json.dumps(receipt,indent=2)+'\n').encode())
    return {k:receipt[k] for k in ('qualification','source_contract_passed','manifest_sha256','payloads','hardware_defines')}


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','sim','out','started-sha256','closed-sha256','model-sha256'):ap.add_argument('--'+name,required=True)
    try:print(json.dumps(freeze(ap.parse_args())))
    except (FreezeError,OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as exc:
        raise SystemExit('bus-cancellation candidate freeze refused: '+str(exc)) from exc


if __name__=='__main__':main()
