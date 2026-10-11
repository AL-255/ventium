#!/usr/bin/env python3
"""Observe actual LGDT/LIDT AXI read bytes without altering the native model.

The contained operand at 0x2ff8 is intentionally an architectural PASS on the
predecessor: its two excess bytes do not cross a page. The physical-bus oracle
must still reject it. --expect-overread is a diagnostic, never a passing gate.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

import observe_fragment_exact_core as observer
from observe_fragment_abort_bus import CORE, sha
from build_fragment_exact_core import load, save, stable


def check_bytes(rows, overread=False):
    assert rows and rows[0]['event'] == 'start'
    first = rows[0]
    assert first['q_ea'] == first['cur_lin_nat'] == 0x2ff8
    assert first['seg_step'] == 0 and first['q_sysop'] in (1, 2)
    assert rows[-1]['event'] == 'done'
    touched = {0: Counter(), 1: Counter()}
    acks = Counter()
    transfers = []
    for row in rows:
        assert row['clk'] == 1 and row['__VnbaTriggered'] & 1
        assert row['state'] == first['state'] and row['q_ea'] == 0x2ff8
        assert row['q_sysop'] == first['q_sysop'] and row['bd_we'] == 0
        step = row['seg_step']
        assert step in (0, 1) and row['fx_act'] == 0
        size = 4 if step == 0 or overread else 2
        assert row['cur_lin_nat'] == 0x2ff8+4*step and row['cur_size'] == size
        assert row['bd_wstrb'] == (0 if overread else (1 << size)-1)
        if row['mem_ack']:
            acks[step] += 1
        if row['m_axi_arvalid'] and row['m_axi_arready']:
            address, width = row['m_axi_araddr'], 1 << row['m_axi_arsize']
            assert row['m_axi_arlen'] == 0 and row['bypass'] == 1
            assert row['fbase'] == 0x2ff8+4*step
            assert width in (1, 2, 4) and address % width == 0
            touched[step].update(range(address, address+width))
            transfers.append(dict(step=step, address=address, bytes=width))
    assert acks == Counter({0: 1, 1: 1})
    for step in (0, 1):
        size = 4 if step == 0 or overread else 2
        assert touched[step] == Counter(range(0x2ff8+4*step, 0x2ff8+4*step+size)), \
            'missing, duplicate, or excess AXI read byte'
    return transfers


SCRIPT = '''set pagination off
set confirm off
set print thread-events off
set disable-randomization off
python
import gdb,json
offsets=OFFSETS
class Observe(gdb.Breakpoint):
    def __init__(self):
        super().__init__('Vventium_top___024root___eval_nba(Vventium_top___024root*)',internal=True)
        self.owner=None
        self.count=0
    def stop(self):
        base=int(gdb.parse_and_eval('$rdi'))
        inferior=gdb.selected_inferior()
        row={k:int.from_bytes(bytes(inferior.read_memory(base+v[0],v[1])),'little') for k,v in offsets.items()}
        if row['clk']!=1 or not row['__VnbaTriggered']&1:
            return False
        if self.owner is None:
            if not (row['mem_req'] and row['bd_req'] and not row['bd_we'] and
                    row['q_ea']==0x2ff8 and row['cur_lin_nat']==0x2ff8 and
                    row['seg_step']==0 and row['q_sysop'] in (1,2)):
                return False
            self.owner=row['state']
            row['event']='start'
        elif row['state']!=self.owner or row['q_ea']!=0x2ff8:
            return False
        elif row['mem_ack'] and row['seg_step']==1:
            row['event']='done'
            self.enabled=False
        elif row['mem_ack'] or (row['m_axi_arvalid'] and row['m_axi_arready']):
            row['event']='transfer'
        else:
            return False
        self.count+=1
        print('DESCRIPTOR_BUS '+json.dumps(row,sort_keys=True))
        if self.count>32:
            raise RuntimeError('unexpected observation volume')
        return False
watch=Observe()
end
run
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('build', 'corpus', 'matrix', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--expect-overread', action='store_true')
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    build, corpus, matrix = (getattr(args, k).resolve(strict=True) for k in ('build', 'corpus', 'matrix'))
    out = args.out.resolve()
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and shutil.disk_usage(scratch).free > 4*1024**3
    obj = build/'obj'
    model = obj/'tb_ventium'
    built = load(build/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['binary_sha256'] == sha(model)
    checked = load(matrix/'closed.json')
    assert checked['pins_unchanged'] and stable(checked['pins'])
    if args.expect_overread:
        assert checked['investigation_completed'] and not checked['candidate_fixed']
        assert sha(model) == 'e4ed9c0c01f53b96fc7da451695feea84b9eabf0891589107711300f042f65c8'
    else:
        assert checked['passed'] and len(checked['cases']) == 24
    paths = [Path(__file__), Path(observer.__file__), Path(observer.__file__).with_name('observe_fragment_abort_bus.py'),
             model, obj/'Vventium_top___024root.h', obj/'Vventium_top__verFiles.dat',
             build/'build-closed.json', matrix/'closed.json']
    pins = {str(p): sha(p) for p in paths}
    out.mkdir()
    save(out/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), diagnostic=args.expect_overread))
    errors, cases, commands = [], [], []
    start = time.monotonic()

    def write(path, text):
        with path.open('x') as stream:
            stream.write(text)
        pins[str(path)] = sha(path)

    def run(leaf, label, argv, expected=0, latency=0):
        argv = ['timeout', '--signal=TERM', '--kill-after=2s', '60s', *map(str, argv)]
        save(leaf/(label+'.command.json'), argv)
        with (leaf/(label+'.stdout')).open('x') as stdout, (leaf/(label+'.stderr')).open('x') as stderr:
            child = subprocess.run(argv, stdout=stdout, stderr=stderr,
                env={**os.environ, 'AXI_RLAT': str(latency), 'AXI_WLAT': str(latency)})
        commands.append(dict(label=str(leaf.name)+'/'+label, native_exit=child.returncode,
            actual_wait=True, stdout_sha256=sha(leaf/(label+'.stdout')), stderr_sha256=sha(leaf/(label+'.stderr'))))
        assert child.returncode == expected, commands[-1]
        text = (leaf/(label+'.stdout')).read_text()
        assert 'Error occurred in Python' not in text+(leaf/(label+'.stderr')).read_text()
        return text

    try:
        # Only this process's offset-generator map is extended; imported files
        # and the separately running/pinned native model remain untouched.
        observer.FIELDS.update({k: CORE+k for k in ('q_ea', 'q_sysop', 'seg_step')})
        write(out/'offsets.cpp', observer.offset_source())
        run(out, 'offset-build', ['g++', '-std=c++20', '-O0', '-I'+str(obj),
            '-I/tools/verilator/v5.046/share/verilator/include',
            '-I/tools/verilator/v5.046/share/verilator/include/vltstd', out/'offsets.cpp', '-o', out/'offsets'])
        offsets = json.loads(run(out, 'offsets', [out/'offsets']))
        assert all(width in (1, 4, 8) for _, width in offsets.values())
        save(out/'offsets.json', offsets)
        for op in ('lgdt', 'lidt'):
            name = op+'-2ff8-cd1'
            image = corpus/name/'fixture.bin'
            for latency in (0, 7):
                leaf = out/(name+f'-lat{latency}')
                leaf.mkdir()
                previous = matrix/name/(f'exact-lat{latency}.vtrace' if args.expect_overread else f'lat{latency}-cycle-func.vtrace')
                pins.update({str(p): sha(p) for p in (image, previous)})
                write(leaf/'observe.gdb', SCRIPT.replace('OFFSETS', repr(offsets)))
                text = run(leaf, 'observe', ['gdb', '-nx', '-batch', '--return-child-result', '-x', leaf/'observe.gdb',
                    '--args', model, '--system', '--cosim', '--l1-axi', '--cycle-func', '--image', image,
                    '--out', leaf/'observed.vtrace', '--max-insn', '3000', '--max-cycles', '3000000',
                    '--quiesce', '8000', '+ven_faultlog'], 133, latency)
                rows = [json.loads(line.removeprefix('DESCRIPTOR_BUS ')) for line in text.splitlines()
                        if line.startswith('DESCRIPTOR_BUS ')]
                save(leaf/'observations.json', rows)
                transfers = check_bytes(rows, args.expect_overread)
                if args.expect_overread:
                    try:
                        check_bytes(rows)
                    except AssertionError:
                        pass
                    else:
                        raise AssertionError('physical oracle accepted predecessor overread')
                assert (leaf/'observed.vtrace').read_bytes() == previous.read_bytes()
                cases.append(dict(case=name, latency=latency, transfers=transfers,
                    whole_trace_bytes_identical=True, byte_exact=not args.expect_overread,
                    observations_sha256=sha(leaf/'observations.json')))
    except Exception as error:
        errors.append(dict(error=repr(error), traceback=traceback.format_exc()))
    unchanged = stable(pins)
    complete = not errors and len(cases) == 4 and unchanged
    result = dict(investigation_completed=complete, byte_exact_gate_passed=complete and not args.expect_overread,
        diagnostic=args.expect_overread, cases=cases, errors=errors, pins=pins, pins_unchanged=unchanged,
        commands=commands, seconds=time.monotonic()-start, gameplay_ipc=None, standard_suite=False)
    save(out/'closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins', 'commands')}), flush=True)
    return 0 if complete else 1


if __name__ == '__main__':
    raise SystemExit(main())
