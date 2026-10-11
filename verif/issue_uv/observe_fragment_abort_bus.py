#!/usr/bin/env python3
"""Read-only host-GDB observation of an existing UV-fast fragment-fault model.

No guest STEP, HDL force, architectural-state injection, model patch or model
rebuild. The tiny C++ program computes offsets from this exact model's header.
This diagnostic requires the full architectural trace to remain byte-identical.
It does not qualify a corrected model or a whole standard suite.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

MODEL_SHA = 'f2797f8c17cb6c7d8668432ae69dd42d427d25a3e3d3b3cd1452de8d6582b4bf'
CORE = 'ventium_top__DOT__u_core__DOT__'
L1 = 'ventium_top__DOT__u_l1axi__DOT__u_l1d__DOT__'
FIELDS = {name: name for name in ('clk', 'm_axi_araddr', 'm_axi_arsize',
    'm_axi_arlen', 'm_axi_arvalid', 'm_axi_arready', '__VnbaTriggered')}
FIELDS.update({name: CORE+name for name in ('fx_act', 'fx_abort_q', 'fx_start',
    'fx_first', 'fx_ph', 'fx_wr', 'cur_lin_nat', 'cur_size', 'cn', 'state',
    'bd_wstrb', 'bd_req', 'bd_we', 'mem_ack')})
FIELDS.update(mem_req='ventium_top__DOT__core_mem_req',
    mem_wstrb='ventium_top__DOT__core_mem_wstrb',
    l1_state=L1+'st', fbase=L1+'fbase', byp_strobes=L1+'byp_wstrb_q',
    byp_count=L1+'byp_cnt_q', bypass=L1+'bypass_q')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--obj', type=Path, required=True)
    parser.add_argument('--case', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    obj, case, out = args.obj.resolve(strict=True), args.case.resolve(strict=True), args.out.resolve()
    model = obj/'tb_ventium'
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert out.is_relative_to(scratch) and not out.exists()
    assert shutil.disk_usage(scratch).free > 4*1024**3 and sha(model) == MODEL_SHA
    paths = [Path(__file__), model, obj/'Vventium_top___024root.h',
        obj/'Vventium_top__verFiles.dat', obj/'Vventium_top___024root__53.cpp',
        case/'fixture.bin', case/'lat0-cycle-func.vtrace', case/'lat0-cycle.vtrace']
    pins = {str(path): sha(path) for path in paths}
    out.mkdir()

    def save(name, value):
        with (out/name).open('x') as stream:
            json.dump(value, stream, indent=2)

    def write(name, value):
        with (out/name).open('x') as stream:
            stream.write(value)
        pins[str(out/name)] = sha(out/name)

    save('started.json', dict(invocation=os.environ['INVOCATION_ID'], pins=pins,
        affinity=sorted(os.sched_getaffinity(0)), passive_host_observation=True))
    rows = []; result = dict(passed=False, errors=[]); began = time.monotonic()

    def run(label, argv, expected=0, seconds=60):
        argv = ['timeout', '--signal=TERM', '--kill-after=2s', f'{seconds}s', *map(str, argv)]
        save(label+'.command.json', argv)
        with (out/(label+'.stdout')).open('x') as stdout, (out/(label+'.stderr')).open('x') as stderr:
            completed = subprocess.run(argv, stdout=stdout, stderr=stderr,
                env={**os.environ, 'AXI_RLAT': '0', 'AXI_WLAT': '0'})
        rows.append(dict(label=label, native_exit=completed.returncode,
            stdout_sha256=sha(out/(label+'.stdout')), stderr_sha256=sha(out/(label+'.stderr'))))
        assert completed.returncode == expected, rows[-1]
        return (out/(label+'.stdout')).read_text()

    try:
        lines = ['#include <cstddef>', '#include <cstdio>', '#include <type_traits>',
            '#include "Vventium_top___024root.h"', 'using Root=Vventium_top___024root;',
            'static_assert(std::is_standard_layout_v<Root>);', 'int main() { std::printf("{");']
        for index, (key, member) in enumerate(FIELDS.items()):
            prefix = ',' if index else ''
            lines.append(f'std::printf("{prefix}\\\"{key}\\\":[%zu,%zu]", '
                f'offsetof(Root,{member}),sizeof(Root::{member}));')
        lines.append('std::printf("}\\n"); }')
        write('offsets.cpp', '\n'.join(lines)+'\n')
        run('offset-build', ['g++', '-std=c++20', '-O0', '-I'+str(obj),
            '-I/tools/verilator/v5.046/share/verilator/include',
            '-I/tools/verilator/v5.046/share/verilator/include/vltstd',
            out/'offsets.cpp', '-o', out/'offsets'], seconds=30)
        offsets = json.loads(run('offsets', [out/'offsets'], seconds=5))
        assert all(width in (1, 4, 8) for _, width in offsets.values())
        save('offsets.json', offsets)
        script = '''set pagination off
set confirm off
set print thread-events off
set disable-randomization off
python
import gdb,json
offsets=OFFSETS
observations=[]
class Observe(gdb.Breakpoint):
    def __init__(self):
        super().__init__('Vventium_top___024root___eval_nba(Vventium_top___024root*)',internal=True)
        self.armed=False
    def stop(self):
        base=int(gdb.parse_and_eval('$rdi'))
        inferior=gdb.selected_inferior()
        row={k:int.from_bytes(bytes(inferior.read_memory(base+v[0],v[1])),'little') for k,v in offsets.items()}
        if row['clk']!=1:
            return False
        if not self.armed:
            if not all(row[k]==1 for k in ('fx_act','fx_abort_q','fx_start','mem_req')):
                return False
            self.armed=True
            row['event']='replacement'
        elif row['state']!=42:
            row['event']='delivery-next-state'
            self.enabled=False
        elif row['m_axi_arvalid'] and row['m_axi_arready']:
            row['event']='axi-ar'
        elif row['mem_ack']:
            row['event']='core-ack'
        else:
            return False
        observations.append(row)
        print('FRAGMENT_BUS_OBSERVATION '+json.dumps(row,sort_keys=True))
        if len(observations)>64:
            raise RuntimeError('unexpected observation volume')
        return False
watch=Observe()
end
run
'''.replace('OFFSETS', repr(offsets))
        write('observe.gdb', script)
        stdout = run('observe', ['gdb', '-nx', '-batch', '--return-child-result', '-x',
            out/'observe.gdb', '--args', model, '--system', '--cosim', '--l1-axi', '--cycle-func',
            '--image', case/'fixture.bin', '--out', out/'observed.vtrace', '--max-insn', '3000',
            '--max-cycles', '3000000', '--quiesce', '8000', '+ven_faultlog'], expected=133)
        observations = [json.loads(line.removeprefix('FRAGMENT_BUS_OBSERVATION '))
            for line in stdout.splitlines() if line.startswith('FRAGMENT_BUS_OBSERVATION ')]
        result['observations'] = observations
        assert observations and observations[0]['event'] == 'replacement'
        first = observations[0]
        assert first['state'] == 42 and first['cur_lin_nat'] == 0x8ffd
        assert first['fx_first'] == 2 and first['bd_we'] == 0 and first['cur_size'] == 4
        assert observations[-1]['event'] == 'delivery-next-state'
        result['whole_trace_bytes_identical'] = (out/'observed.vtrace').read_bytes() == (
            case/'lat0-cycle-func.vtrace').read_bytes()
        assert result['whole_trace_bytes_identical']
        # A legacy whole-dword transfer on the next physical page while the
        # engine is still serving fragment 1 is the bug witness, not a pass.
        result['overread_witnesses'] = [row for row in observations if row['event'] == 'axi-ar'
            and row['m_axi_araddr'] == 0x9000 and row['m_axi_arsize'] == 2
            and row['fx_ph'] == 0 and row['fbase'] == 0x8ffd and row['bypass'] == 1]
        assert result['overread_witnesses'], 'expected predecessor overread was not observed'
        result['passed'] = True
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins=pins, pins_unchanged=all(sha(path)==value for path, value in pins.items()),
        rows=rows, seconds=time.monotonic()-began, diagnostic_only=True, repaired_model=False)
    result['passed'] &= result['pins_unchanged']
    save('closed.json', result)
    print(json.dumps({key:value for key,value in result.items() if key!='pins'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
