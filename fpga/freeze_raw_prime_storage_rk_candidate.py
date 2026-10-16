"""Seal RAW-storage + retained 8042 + tested FPGA keyboard retry together.

Export only: no Vivado or board actions and no timing/guest acceptance inherited.
All 170 common HDL files and all 192 parent payloads are checked, not just the
three deltas. Large evidence files are hashed without retaining their contents.
"""
import argparse
import json
import os
from pathlib import Path
import shutil

import build_raw_prime_storage_soc as native
import sfetch_boundary_evidence as parent_evidence
import freeze_backing_direction_rk_candidate as common
import prepare_kbd_inhibit as injector
import run_kbd_mmio as mmio
from freeze_rk_candidate import (directory, frozen_path, overlaps, publish_new,
    sha256, snapshot, unchanged, write_new)

base, require = common.base, common.require
PARENT = parent_evidence.MANIFEST
MODEL = 'e9159acb28b80a9511a87cfca1872ab907f43eb3e6f2956dc1a3d3150bcd0fd7'
VARIANT = 'raw_prime_storage_retained_input_unqualified'
INJECTOR = 'flow/src/ven_ps2_kbd_inject.v'
CONTROLLER = 'ventium/'+native.parent_build.ui.PS2
CPU = 'ventium/'+native.recipe.FILE
CHANGES = sorted((CPU, CONTROLLER, INJECTOR))


def check_delta(name, before, after):
    if name == CPU:
        return native.check_delta(native.recipe.FILE, before, after)
    if name == CONTROLLER:
        return native.parent_build.check_delta(native.parent_build.ui.PS2, before, after)
    if name == INJECTOR:
        require(injector.transform(before.decode()).encode() == after, 'unreviewed keyboard endpoint')
        return True
    require(before == after, 'unreviewed source change: '+name)
    return False


def check_profile(old, start, closed, definitions):
    require(old['variant'] == parent_evidence.VARIANT and old['qualification'] == 'UNQUALIFIED', 'wrong hardware parent')
    require(old['processor_platform_simulator_sha256'] == parent_evidence.MODEL, 'wrong parent CPU')
    require((old['core_mhz'], old['write_slots'], old['l2_sets']) == (40,16,1024), 'geometry drift')
    require(start['parent_model'] == native.PARENT_MODEL and start['directed_model'] == native.CORE_MODEL, 'wrong compiled CPU')
    require(start['changes'] == [native.recipe.FILE] and start['added_defines'] == [], 'extra CPU changes')
    require(start['controller_sha256'] == mmio.template.CONTROLLER_SHA and start['binding_read_wire'] == 'kb_fifo_rdreq', 'input repair lost')
    require(not start['canonical_gate_passed'] and not start['legacy_aggregate_gate_passed'], 'failure policy changed')
    require(closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged'] and closed['binary_sha256'] == MODEL, 'PC build not closed')
    native.transfer.check_definitions(start['command'], definitions)
    hw = old['hardware_defines']
    require(len(hw) == len(set(hw)) == 159 and set(hw)-{'SYNTHESIS','VTM_NO_DPI'} == set(definitions), 'profile mismatch')


def freeze(parent, sim, build_unit, out):
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    require(__debug__ and Path(os.environ['TMPDIR']).resolve() == scratch and
            scratch.stat().st_dev != native.REPO.stat().st_dev and shutil.disk_usage(scratch).free > 4*1024**3, 'scratch admission')
    require(sim == native.ROOT/'raw-prime-storage-soc-r1' and out.parent == native.ROOT and not out.exists(), 'fresh exact output required')
    require(not any(overlaps(out,p) for p in (parent,sim,native.REPO)), 'overlapping output')
    observed, aliases = {}, {}
    def read(p, digest=None, size=None):
        actual = p.resolve(strict=True); aliases[p] = actual
        return base.read_observed(observed, actual, digest, size)['data']
    def js(p, digest=None): return json.loads(read(p, digest))
    old = js(parent/'input-manifest.json', PARENT)
    prior = js(parent/'freeze-receipt.json')
    require(prior['manifest_sha256'] == PARENT and prior['preprocessing_passed'], 'unsealed parent')
    for p,h in parent_evidence.check(parent).items(): read(Path(p),h)
    start, closed = js(sim/'build-started.json'), js(sim/'build-closed.json')
    definitions = read(sim/'defines.txt').decode().splitlines()
    check_profile(old, start, closed, definitions)
    owner = common.parent_flow.closed_owner(build_unit,start['invocation'])
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted', MODEL)
    for p,h in start['pins'].items(): read(Path(p),h)
    base.check_native_command(read(sim/'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat').decode(),start['command'])
    # The original, independently audited integration controls must close first.
    for folder in (native.ROOT/'raw-prime-storage-input-r1', sim/'coremark-ui-disabled-r1', native.ROOT/'kbd-mmio-r1'):
        audit, began, done = [js(folder/n) for n in ('audit.json','started.json','closed.json')]
        require(audit['passed'] and done['passed'] and done['pins_unchanged'], 'integration evidence failed')
        require(not audit['standard_suite'] and audit['gameplay_ipc'] is None, 'incorrect acceptance inheritance')
        if folder.name == 'kbd-mmio-r1':
            require((audit['candidate_positive_cases'],audit['original_endpoint_positive_controls'],audit['original_endpoint_red_witnesses']) == (12,6,6), 'wrong MMIO corpus')
            require(audit['endpoint_sha256'] == mmio.template.FIXED_SHA and audit['controller_sha256'] == mmio.template.CONTROLLER_SHA, 'endpoint mismatch')
            require(audit['management_sha256'] == mmio.MGMT_SHA and audit['debug_mmio_tested'] and not audit['full_wrapper'], 'MMIO scope drift')
        else:
            require(audit['model'] == MODEL, 'wrong PC evidence')
        for pins in (began['pins'], audit.get('artifacts',{}), audit.get('artifact_pins',{})):
            for p,h in pins.items(): read(Path(p),h)
    hw = read(parent/'defines.txt')
    require(hw == ('\n'.join(old['hardware_defines'])+'\n').encode(), 'define file drift')
    payload, origins, original, changed = {}, {}, {}, []
    compiled = 0
    for row in old['files']:
        name = frozen_path(row['frozen']); require(name not in original, 'duplicate payload')
        before = read(parent/name,row['sha256'],row['bytes']); original[name] = data = before
        source = parent/name
        if name.startswith('ventium/') and Path(name).suffix in base.SUFFIXES:
            source = sim/'source'/name.removeprefix('ventium/')
            require(str(source) in start['pins'], 'source not compiled: '+name)
            data = read(source,start['pins'][str(source)])
            if name == base.SYSTEM: data = base.projection(before,data)
            else: compiled += 1
        elif name == INJECTOR:
            source = mmio.template.FIXED
            data = read(source,mmio.template.FIXED_SHA)
        if check_delta(name,before,data): changed.append(name)
        payload[name], origins[name] = data, source
    require(sorted(changed) == CHANGES and compiled == 170 and len(payload) == 192, 'incomplete source match')
    require(sha256(payload[CONTROLLER]) == mmio.template.CONTROLLER_SHA, 'controller lost')
    require(sha256(payload[INJECTOR]) == mmio.template.FIXED_SHA, 'retry fix lost')
    require(sha256(payload['flow/src/ven_mgmt_axil.v']) == mmio.MGMT_SHA, 'management changed')
    require(sha256(payload[common.mouse.repair.WRAPPER]) == common.mouse.WRAPPER_SHA, 'posted mouse fix lost')
    require(base.source_closure({n:dict(data=b) for n,b in payload.items()}) == old['source_closure'], 'filelist drift')
    for module in (native,parent_evidence,common,injector,mmio,mmio.template,base,common.mouse,common.mouse.repair):
        read(Path(module.__file__).resolve())
    read(Path(__file__).resolve()); read(native.REPO/'fpga/freeze_rk_candidate.py'); read(Path('/usr/bin/iverilog'))
    def stable():
        for p,info in observed.items(): unchanged(p,info)
        require(all(p.resolve(strict=True) == q for p,q in aliases.items()), 'input alias drift')
    stable(); out.mkdir(); identity = directory(out); rows = []
    for name,data in payload.items():
        write_new(out/name,data)
        rows.append(dict(frozen=name,source=str(origins[name]),sha256=sha256(data),bytes=len(data),parent_sha256=sha256(original[name])))
    write_new(out/'defines.txt',hw)
    checks = []
    for label,defs in (('posted_exact159',old['hardware_defines']),('nonposted_control',[n for n in old['hardware_defines'] if n != 'VEN_DDR_POSTED'])):
        text = common.mouse.repair.preprocess(out/common.mouse.repair.WRAPPER,defs)
        common.mouse.repair.check_devices(text)
        write_new(out/(label+'.preprocessed.v'),text.encode())
        checks.append(dict(profile=label,defines=defs,both_devices_present=True,preprocessed_sha256=sha256(text.encode()),elaborated=False))
    stable(); require(directory(out) == identity, 'output identity drift')
    for row in rows: snapshot(out/row['frozen'],row['sha256'],row['bytes'])
    manifest = dict(old,variant=VARIANT,files=rows,parent_manifest_sha256=PARENT,
        changed_parent_payloads=CHANGES,changed_flow_payloads=[INJECTOR],added_payloads=[],
        simulator_sha256=None,processor_platform_simulator_sha256=MODEL,
        full_wrapper_elaborated=False,full_soc_lint=False,canonical_gate_passed=False,
        standard_suite=False,hardware_acceptance=False,fmax_mhz=None,gameplay_ipc=None,
        note='Exact RAW-storage/retained-8042/injector composition. Posted mouse wrapper unchanged. No timing, full-wrapper, guest or physical acceptance inherited.')
    publish_new(out/'input-manifest.json',(json.dumps(manifest,indent=2)+'\n').encode())
    receipt = dict(qualification='UNQUALIFIED',source_contract_passed=False,preprocessing_passed=True,
        full_wrapper_elaborated=False,payloads=len(rows),compiled_common_hdl=compiled,
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),build_owner=owner,checks=checks,
        input_pins={str(p):info['sha256'] for p,info in observed.items()},
        input_aliases={str(p):str(q) for p,q in aliases.items()},complete_wrapper_or_board_qualified=False)
    publish_new(out/'freeze-receipt.json',(json.dumps(receipt,indent=2)+'\n').encode())
    return {k:receipt[k] for k in ('qualification','payloads','compiled_common_hdl','manifest_sha256')}


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','sim','out'): ap.add_argument('--'+name,type=Path,required=True)
    ap.add_argument('--build-unit',required=True)
    a = ap.parse_args()
    print(json.dumps(freeze(a.parent.resolve(strict=True),a.sim.resolve(strict=True),a.build_unit,a.out.resolve())))
