#!/usr/bin/env python3
"""Export an exact simulated performance/L2 source to an UNQUALIFIED FPGA bundle.

No Vivado, board access, acceptance inheritance, source discovery or live RTL
edits. The one simulator-only system wrapper is projected back onto the pinned
hardware top; every other compiled RTL/header/filelist is copied byte-for-byte.
The explicit sfetch16 variant adds only the demand-fetch define and requires
the separately compiled estimator-width change. A wrapper update is separately
SHA-pinned; it never silently copies scripts from the working checkout.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

from freeze_rk_candidate import (FreezeError, absolute_path, checked_sha,
    directory, frozen_path, overlaps, publish_new, sha256, snapshot,
    unchanged, unique_json, write_new)

ADDITIONS = ('SYNTHESIS', 'VTM_NO_DPI', 'VEN_ALTSYNCRAM_XPM')
PERF_DEFINES = tuple('''VEN_AXI2AVL_READ_THROUGH VEN_FP_ARITH_MEM_FWD
VEN_FP_MEM_QUEUE64 VEN_FP_POP_DRAIN VEN_FP_RESIDENT_PRIME VEN_FP_SCALAR_DISPATCH
VEN_FP_SCALAR_LOAD_CMD VEN_FP_SHORT_WINDOW VEN_IFETCH_AUTH_MULTI
VEN_L1D_CODE_WORD_REUSE VEN_L1D_DATA_UNDER_IFILL VEN_L1D_PRIME_UNDER_FILL
VEN_L1D_TAG_LUTRAM VEN_P54_CTRL_TARGET_SYSTEM VEN_PIPE_MEM_CHAIN
VEN_PIPE_REG_LOAD_PRIME VEN_RAW_AGI_PRIME VEN_RAW_HELD_READ_PRIME
VEN_RAW_V_READ_PRIME VEN_REF_OPERAND_PRIME VEN_REP_CONT_NO_UOP'''.split())
SYSTEM = 'ventium/3rd-party/ao486_MiSTer/rtl/system.v'
CHANGES = frozenset('ventium/' + p for p in (
    '3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v',
    '3rd-party/ao486_MiSTer/rtl/system.v', 'ao486-sim/ven/ven_axi2avalon.sv',
    'fp_shared/ven_fp_alu.sv', 'fp_shared/ven_fp_fxch_queue.sv',
    'fp_shared/ven_fp_top.sv', 'rtl/core/core.sv',
    'rtl/core/core_ctrl_target_read.svh', 'rtl/core/core_fp_async.svh',
    'rtl/core/core_mem_chain.svh', 'rtl/mem/ven_l1d.sv'))
NEW_HEADERS = tuple('ventium/rtl/core/' + name for name in (
    'core_ifetch_auth_multi.svh', 'core_fp_scalar_dispatch.svh',
    'core_raw_held_prime.svh', 'core_ref_operand_prime.svh',
    'core_agi_resident_prime.svh'))
SUFFIXES = ('.v', '.sv', '.vh', '.svh', '.f')
WRAPPER = 'ventium/fpga/create_project_3mhz_wrapper.tcl'
VARIANT_DEFINES = {'performance': (), 'sfetch16': ('VEN_SFETCH16_DEMAND',)}


def require(ok, message):
    if not ok:
        raise FreezeError(message)


def profile(parent, simulated, variant='performance'):
    require(variant in VARIANT_DEFINES, 'unknown performance variant')
    extra = VARIANT_DEFINES[variant]
    require(len(parent) == len(set(parent)) == 114 and tuple(parent[-3:]) == ADDITIONS
            and parent[110] == 'VEN_DDR_POSTED', 'wrong posted/banked parent profile')
    require(not set(parent) & (set(PERF_DEFINES) | {'VEN_SFETCH16_DEMAND'}), 'already extended parent')
    require(len(simulated) == len(set(simulated)) == 133 + len(extra), 'wrong simulated profile count')
    hardware = parent[:-3] + list(PERF_DEFINES) + list(extra) + list(ADDITIONS)
    require(set(simulated) == set(hardware) - {'SYNTHESIS', 'VTM_NO_DPI'},
            'simulated definitions differ from reviewed performance profile')
    for definition in hardware:
        require(re.fullmatch(r'[A-Z][A-Z0-9_]*', definition), 'invalid definition')
    return hardware


def once(text, old, new):
    require(text.count(old) == 1, 'missing/ambiguous system anchor: ' + repr(old))
    return text.replace(old, new)


def hardware_system(parent, simulated):
    """Keep parent CRLF/ports; prove *only* geometry plus known sim instrumentation."""
    require(b'CACHE_SETS' not in parent, 'already parameterized hardware parent')
    hardware = once(parent, b'l2_cache cache', b'l2_cache #(.CACHE_SETS(1024)) cache')
    # The existing simulator preparation uses read_text/write_text, hence LF.
    expected = hardware.decode().replace('\r\n', '\n')
    expected = once(expected, 'module system\n(',
        'module system #(parameter BOARD_POSTED=1, parameter BOARD_WRITE_SLOTS=16)\n(\n'
        '`include "board_transport_ports.svh"')
    expected = once(expected, 'l2_cache #(.CACHE_SETS(1024)) cache',
        '`include "board_transport_body.svh"\n\nl2_cache #(.CACHE_SETS(1024)) cache')
    for port, net in (('DDRAM_BUSY', 'board_ddram_busy'), ('DDRAM_DOUT', 'board_ddram_data'),
                      ('DDRAM_DOUT_READY', 'board_ddram_valid'), ('dbg_cmp', 'board_dbg_cmp')):
        live = 'cpu_dbg_cmp' if port == 'dbg_cmp' else port
        expected, count = re.subn(r'(\.'+port+r'\s*\()'+live+r'(\))',
                                  r'\g<1>'+net+r'\2', expected)
        require(count == 1, 'ambiguous board-model connection: ' + port)
    require(expected.encode() == simulated, 'unexpected simulator system delta')
    return hardware


def source_closure(payload):
    """Resolve literal filelists/includes entirely inside the exported payload.

    Check even conditional includes: no build is allowed to fall back to a
    header from the working checkout. This is source closure, not elaboration.
    """
    include_dirs, units = {'ventium'}, set()
    for name in ('rtl_ven_core.f', 'rtl_ven_soc.f'):
        for line in payload['ventium/'+name]['data'].decode().splitlines():
            line = line.strip()
            if not line or line.startswith(('//', '#')):
                continue
            if line.startswith('+incdir+'):
                include_dirs.add('ventium/'+frozen_path(line.removeprefix('+incdir+')))
                continue
            require(not line.startswith(('+', '-')), 'hidden filelist directive: '+line)
            unit = 'ventium/'+frozen_path(line)
            require(unit in payload, 'unresolved filelist input: '+line)
            units.add(unit)
    edges = 0
    for name, item in payload.items():
        if Path(name).suffix not in SUFFIXES[:-1]:
            continue
        # Ignore commented examples, but preserve ordinary string contents.
        body = re.sub(r'/\*.*?\*/|//[^\n]*', '', item['data'].decode(), flags=re.S)
        for tail in re.findall(r'`include\b([^\n]*)', body):
            match = re.fullmatch(r'\s*"([^"\n]+)"\s*', tail)
            require(match is not None, 'nonliteral include in '+name)
            header = frozen_path(match[1])
            roots = include_dirs | {str(Path(name).parent)}
            resolved = {root+'/'+header for root in roots if root+'/'+header in payload}
            require(len(resolved) == 1, 'missing/ambiguous include in '+name+': '+header)
            edges += 1
    return dict(filelist_units=len(units), include_edges=edges)


def freeze(args):
    parent, sim, repo, out = map(absolute_path, (args.parent, args.sim, args.repo, args.out))
    identities = {p: directory(p) for p in (parent, sim, repo, out)}
    require(not any(overlaps(out, p) for p in (parent, sim, repo)) and not any(out.iterdir()),
            'output must be empty and outside all input roots')
    observed, aliases = {}, {}
    def read(path, digest=None, size=None):
        data = snapshot(path, digest, size)
        if path in observed:
            require(observed[path]['fingerprint'] == data['fingerprint']
                    and observed[path]['sha256'] == data['sha256'], 'input changed between reads')
        observed[path] = data
        return data
    def js(path, digest=None):
        return json.loads(read(path, digest)['data'], object_pairs_hook=unique_json)
    manifest = js(parent/'input-manifest.json', checked_sha(args.parent_sha256))
    started = js(sim/'build-started.json', checked_sha(args.started_sha256))
    closed = js(sim/'build-closed.json', checked_sha(args.closed_sha256))
    prepared = js(sim/'prepared.json')
    require(manifest['schema'] == 1 and manifest['core_mhz'] == 40 and len(manifest['files']) == 181,
            'expected the 181-payload forty-MHz posted parent')
    parent_defs = manifest['hardware_defines']
    require(read(parent/'defines.txt')['data'] == ('\n'.join(parent_defs)+'\n').encode(), 'parent define drift')
    sim_defs = read(sim/'defines.txt')['data'].decode().splitlines()
    hardware_defs = profile(parent_defs, sim_defs, args.variant)
    expected_changes = CHANGES
    if args.variant == 'sfetch16':
        expected_changes = CHANGES | {'ventium/fp_shared/ven_fp_estdiv.sv'}
        require(prepared['rtl_changes'] == ['fp_shared/ven_fp_estdiv.sv', 'rtl/core/core.sv']
                and prepared['added_defines'] == ['VEN_SFETCH16_DEMAND'],
                'wrong demand-fetch native derivative')
        require(args.wrapper_sha256 is not None, 'demand-fetch export requires an explicit wrapper pin')
    command = started['command']
    actual_defs = [s[2:] for s in command if s.startswith('-D')]
    actual_defs += [s[8:] for s in command if s.startswith('+define+')]
    require(len(actual_defs) == len(sim_defs) and set(actual_defs) == set(sim_defs),
            'actual compile define drift')
    require('-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command,
            'actual compile lacks sixteen-slot board transport')
    require(closed['passed'] is True and closed['native_exit'] == 0 and closed['inputs_unchanged'] is True,
            'simulated build did not close successfully')
    require(prepared['l2_sets'] == 1024 and prepared['l2_bytes'] == 262144
            and prepared['xpm_fidelity'] is True, 'wrong simulated L2 profile')
    require(closed['binary_sha256'] == checked_sha(args.model_sha256), 'unexpected model identity')
    read(sim/'obj1-speed-q16-parentpolicy/ao486sim_board_posted', args.model_sha256)
    for path, digest in started['pins'].items():
        pinned = absolute_path(path)
        resolved = pinned.resolve(strict=True)
        if resolved != pinned:
            # The native receipt used ~/external only for its build driver.
            # No RTL/model/root alias is admitted; pin the exact driver bytes
            # and recheck this one alias before publishing the result.
            require(resolved == sim/'build.py', 'unexpected aliased native pin: '+path)
            aliases[pinned] = resolved
        read(resolved, checked_sha(digest))
    # These include files are not exported. Check that the inspected simulation
    # wrapper actually uses the existing real transport, drain and port adapter.
    for name in ('ports', 'body', 'connections'):
        relative = f'ao486-sim/ven/board_transport_{name}.svh'
        data = read(repo/relative)
        require(read(sim/'source'/relative)['sha256'] == data['sha256'], 'board-model adapter drift')
    payload, changes = {}, set()
    for record in manifest['files']:
        name = frozen_path(record['frozen'])
        require(name not in payload and name not in ('input-manifest.json', 'defines.txt', 'freeze-receipt.json'),
                'duplicate/reserved payload')
        prior = read(parent/name, checked_sha(record['sha256']), record['bytes'])
        data, source = prior['data'], parent/name
        if name.startswith('ventium/') and Path(name).suffix in SUFFIXES:
            source = sim/'source'/name.removeprefix('ventium/')
            require(str(source) in started['pins'], 'hardware input absent from native build: '+name)
            data = read(source, started['pins'][str(source)])['data']
            if name == SYSTEM:
                data = hardware_system(prior['data'], data)
            if sha256(data) != prior['sha256']:
                changes.add(name)
        payload[name] = dict(data=data, parent=prior, source=source)
    require(changes == expected_changes,
            'unreviewed/missing hardware deltas: '+repr(sorted(changes ^ expected_changes)))
    for name in NEW_HEADERS:
        require(name not in payload, 'new header already exists in parent: '+name)
        source = sim/'source'/name.removeprefix('ventium/')
        require(str(source) in started['pins'], 'new header absent from native build: '+name)
        data = read(source, checked_sha(started['pins'][str(source)]))['data']
        payload[name] = dict(data=data, parent=None, source=source)
    flow_changes = []
    if args.wrapper_sha256 is not None:
        require(WRAPPER in payload, 'parent wrapper missing')
        source = repo/'fpga/create_project_3mhz_wrapper.tcl'
        data = read(source, checked_sha(args.wrapper_sha256))['data']
        require(sha256(data) != payload[WRAPPER]['parent']['sha256'], 'redundant wrapper override')
        payload[WRAPPER].update(data=data, source=source)
        flow_changes.append(WRAPPER)
    closure = source_closure(payload)
    checker = repo/'fpga/test_rk_wrapper.tcl'
    for p in (Path(__file__).resolve(), repo/'fpga/freeze_rk_candidate.py', checker): read(p)
    for p, d in observed.items(): unchanged(p, d)
    require(all(p.resolve(strict=True) == target for p,target in aliases.items()),
            'native driver alias changed')
    records = []
    for name, item in payload.items():
        data = item['data']; write_new(out/name, data)
        records.append(dict(frozen=name, source=str(item['source']), sha256=sha256(data), bytes=len(data),
            parent_sha256=item['parent']['sha256'] if item['parent'] else None,
            provenance='explicit_sha_pinned_flow_update' if name in flow_changes else
                       'geometry_only_hardware_projection' if name == SYSTEM else
                       'native_compiled_source' if name.startswith('ventium/') and Path(name).suffix in SUFFIXES else
                       'parent_payload_historical_ancestry_only'))
    write_new(out/'defines.txt', ('\n'.join(hardware_defs)+'\n').encode())
    result = subprocess.run(['tclsh',str(checker),str(out/'ventium/fpga/create_project_3mhz_wrapper.tcl'),
        str(out/'flow'),str(out/'defines.txt'),str(out/'ventium'),str(out/'template'),args.synthesis_profile],
        capture_output=True,text=True,timeout=15)
    write_new(out/'source-contract.log', (result.stdout+result.stderr).encode())
    require(result.returncode == 0 and f'exact{len(hardware_defs)}defs' in result.stdout
            and 'POSTED-DDR-SOURCE-CONTRACT-OK' in result.stdout, 'hardware source contract refused')
    for p, d in observed.items(): unchanged(p, d)
    require(all(p.resolve(strict=True) == target for p,target in aliases.items()),
            'native driver alias changed')
    require(all(directory(p) == identity for p, identity in identities.items()), 'directory identity changed')
    for row in records: snapshot(out/row['frozen'], row['sha256'], row['bytes'])
    info = dict(schema=1, qualification='UNQUALIFIED', core_mhz=40,
        simulator_defines=len(sim_defs), hardware_additions=['SYNTHESIS','VTM_NO_DPI'],
        simulator_already_uses_xpm_fidelity=True, hardware_defines=hardware_defs,
        parent_manifest_sha256=args.parent_sha256, simulator_sha256=args.model_sha256,
        simulator_started_sha256=args.started_sha256, simulator_closed_sha256=args.closed_sha256,
        changed_parent_payloads=sorted(changes), added_payloads=list(NEW_HEADERS),
        variant=args.variant, changed_flow_payloads=flow_changes,
        source_contract_synthesis_profile=args.synthesis_profile,
        files=records, write_slots=16, l2_sets=1024,
        source_closure=closure,
        inherited_simulator_structural_warning_count=closed.get('structural_debt_count'),
        note='Source/provenance checks only; not a clean lint, suite, gameplay, timing or FPGA acceptance.')
    publish_new(out/'input-manifest.json', (json.dumps(info,indent=2)+'\n').encode())
    receipt = dict(qualification='UNQUALIFIED', source_contract_passed=True,
        manifest_sha256=sha256((out/'input-manifest.json').read_bytes()),
        input_pins={str(p):d['sha256'] for p,d in observed.items()},
        native_driver_aliases={str(p):str(target) for p,target in aliases.items()},
        payloads=len(records), hardware_defines=len(hardware_defs),
        note='No Vivado or board operation; model acceptance is not transferred to hardware.')
    publish_new(out/'freeze-receipt.json', (json.dumps(receipt,indent=2)+'\n').encode())
    return {k:receipt[k] for k in ('qualification','source_contract_passed','manifest_sha256','payloads','hardware_defines')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','parent-sha256','sim','started-sha256','closed-sha256','model-sha256','repo','out'):
        parser.add_argument('--'+name, required=True)
    parser.add_argument('--variant', choices=VARIANT_DEFINES, default='performance')
    parser.add_argument('--wrapper-sha256', help='explicit opt-in to the pinned working-tree wrapper')
    parser.add_argument('--synthesis-profile', choices=('legacy','balanced','logic_only'), default='balanced')
    try:
        print(json.dumps(freeze(parser.parse_args())))
    except (FreezeError,OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as exc:
        raise SystemExit('performance freeze refused: '+str(exc)) from exc


if __name__ == '__main__': main()
