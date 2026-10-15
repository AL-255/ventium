#!/usr/bin/env python3
"""Exercise unchanged finite-CS BIOSes despite the retained QEMU limitation.

This is a self-checking RTL diagnostic and full parent/candidate replay, NOT a
QEMU differential pass. Neither the original failed gate nor its images change.
No compilation, new oracle, snapshot, breakpoint or slow-mode control is used.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

REPO = Path(__file__).resolve().parents[2]
DATA = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve()
sys.path[:0] = [str(REPO/'fpga'), str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import native_observation
import tracefmt
import check_faultlog

spec = importlib.util.spec_from_file_location('native', REPO/'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
MODELS = {
    'parent': ('prefix-payload-core-r1', 'e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6'),
    'candidate': ('fetch-fragment-core-r1', '0698ce2f2e0de10ec1952704b63b40fd70fc8cbb682171d5ed83cade6e612c6c'),
}
CASES = [f'k2-r{reloc}-o{offset}' for reloc in (0, 1) for offset in (4080, 4093, 4094, 4095)]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def parse_cmdline(raw):
    assert raw and raw.endswith(b'\0'), 'incomplete proc argv'
    return raw[:-1].decode().split('\0')


def model_definitions(command):
    definitions = re.findall(r'\+define\+(\w+)', command)
    counts = Counter(definitions)
    # The TB Makefile adds VEN_FPREM before the unchanged 152-definition file.
    assert len(definitions) == 153 and len(counts) == 152 and ' --assert ' in command
    assert {name: count for name,count in counts.items() if count != 1} == {'VEN_FPREM': 2}
    return definitions


def precise_gp(stdout, hot):
    check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()), {(13, 0): 1})
    rows = [check_faultlog.FAULT.fullmatch(line) for line in stdout.splitlines() if '[FAULT]' in line]
    assert len(rows) == 1
    pc = re.search(r' pc=([0-9a-fA-F]{8}) ', rows[0][0])
    assert pc and int(pc[1], 16) == hot, 'wrong fault restart EIP'


def require_backend_activity(stdout):
    rows = re.findall(r'^\[L1DPERF\] fill cycles=(\d+) backing-wait=(\d+) backing-ack=(\d+)$', stdout, re.M)
    assert len(rows) == 1 and int(rows[0][0]) > 0 and int(rows[0][2]) > 0, 'no L1 backing activity'


def check_trace_shape(trace, mode):
    assert trace.hdr['producer'] == 'rtl' and not trace.x87
    assert trace.mode == ('func' if mode == 'cycle-func' else 'cycle')
    assert 100 < len(trace.records) < 2000
    assert [row['n'] for row in trace.records] == list(range(len(trace.records)))
    if mode == 'cycle-func':
        assert trace.hdr['sys'] is True
        assert int(trace.records[-1]['eax'], 0) & 255 == 0x42


def pair_witness(records, symbols):
    paired = [row for row in records if row.get('paired') and row.get('pipe') == 'V']
    assert paired, 'UV never exercised'
    for row in paired:
        previous = records[row['n']-1]
        assert row['n'] > 0 and previous['pipe'] == 'U' and previous['cyc'] == row['cyc']
    # Static assembly labels do not force dynamic U/V alignment: an alignment
    # NOP may take U and pair_u may take V, leaving pair_v in the next U slot.
    # Require both real instructions plus actual pairing within this control.
    for name in ('pair_u', 'pair_v'):
        assert sum(int(row['pc'], 0) == symbols[name] for row in records) == 1
    assert any(symbols['pair_u'] <= int(row['pc'], 0) <= symbols['pair_v']+5 for row in paired)
    return paired


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 4*1024**3
    assert os.sched_getaffinity(0) == {13, 14, 15, 16}
    invocation = os.environ['INVOCATION_ID']
    group = Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert (group/'memory.max').read_text().strip() == str(1024**3)
    assert (group/'memory.swap.max').read_text().strip() == '0'
    original = DATA/'prefix-payload-boundary-r1'
    reference = DATA/'qemu-tb-page-native-r2'
    reference_start = json.loads((reference/'started.json').read_text())
    reference_closed = json.loads((reference/'closed.json').read_text())
    assert reference_closed['native_backport_passed'] and reference_closed['pins_unchanged']
    assert reference_closed['finite_cs_limit_discrepancy_unfixed']
    assert not reference_closed['original_boundary_gate_passed']
    pins = {}
    for path in (Path(__file__), Path(native_observation.__file__), Path(native.__file__),
                 Path(tracefmt.__file__), Path(check_faultlog.__file__),
                 reference/'started.json', reference/'closed.json',
                 REPO/'verif/fe_pipe/prefix66-boundary.S'):
        pins[str(path)] = sha(path)
    prior = json.loads((original/'started.json').read_text())
    source = str(REPO/'verif/fe_pipe/prefix66-boundary.S')
    assert pins[source] == prior['pins'][source]
    models, definitions, symbols = {}, {}, {}
    for label, (name, digest) in MODELS.items():
        model = DATA/name/'obj/tb_ventium'
        assert sha(model) == digest
        stamp = model.parent/'Vventium_top__verFiles.dat'
        command = next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
        defs = model_definitions(command)
        assert {'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SEG_ENFORCE',
                'VEN_FE_PIPE', 'VEN_L1_AXI', 'VEN_P54_PREFIX66_SYSTEM'} <= set(defs)
        assert not {'SYNTHESIS', 'VTM_NO_DPI', 'VEN_UOPCACHE', 'VEN_SYS_FASTPATH_ALL'} & set(defs)
        models[label], definitions[label] = model, defs
        for path in (model, stamp): pins[str(path)] = sha(path)
    assert definitions['parent'] == definitions['candidate']
    for case in CASES:
        old_row = next(row for row in reference_closed['rows'] if row['case'] == case)
        assert all(row['native_exit'] == 135 for row in old_row['rows'])
        for suffix in ('bin', 'elf'):
            path = original/case/('test.'+suffix)
            assert sha(path) == reference_start['pins'][str(path)]
            pins[str(path)] = sha(path)
        assert old_row['image_sha256'] == sha(original/case/'test.bin')
        syms = dict((parts[2], int(parts[0], 16)) for line in subprocess.check_output(
            ['nm', '-n', original/case/'test.elf'], text=True).splitlines()
            if len(parts := line.split()) == 3 and parts[0] != 'U')
        assert syms['hot_probe'] == 0x2f000+int(case.split('-o')[1])
        symbols[case] = syms
    root.mkdir()
    save(root/'started.json', dict(pins=pins, invocation=invocation, cases=CASES,
        definitions=definitions, models={k:str(v) for k,v in models.items()},
        original_gate_passed=False, qemu_differential=False, diagnostic_only=True))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VTM_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(TMPDIR=str(root), PYTHONDONTWRITEBYTECODE='1')

    def one(index_case):
        index, case = index_case
        leaf = root/case
        leaf.mkdir()
        rows, records = [], {}
        for label, model in models.items():
            for latency in (0, 7, 31):
                counts = []
                for mode in ('cycle-func', 'cycle'):
                    stem = f'{label}-lat{latency}-{mode}'
                    path = leaf/(stem+'.vtrace')
                    argv = [str(model), '--system', '--cosim', '--'+mode, '--l1-axi',
                        '--image', str(original/case/'test.bin'), '--out', str(path),
                        '--max-insn', '2000', '--max-cycles', '1000000', '--quiesce', '4096', '+ven_faultlog']
                    command = ['taskset', '-c', str(13+index%4), *argv]
                    receipt = dict(command=command, latency=latency, actual_wait=False, reaped=False)
                    begin = time.monotonic()
                    with (leaf/(stem+'.stdout')).open('x') as out, (leaf/(stem+'.stderr')).open('x') as err:
                        child = subprocess.Popen(command, stdout=out, stderr=err,
                            env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)))
                        try:
                            receipt['observed'] = native_observation.observe_owned_native(
                                child, model, argv, None, 13+index%4, parse_cmdline)
                            receipt['native_exit'] = child.wait(timeout=45)
                        finally:
                            if child.poll() is None:
                                child.terminate()
                                try: child.wait(timeout=3)
                                except subprocess.TimeoutExpired: child.kill(); child.wait()
                            receipt.update(native_exit=child.returncode, actual_wait=True,
                                reaped=not Path('/proc', str(child.pid)).exists(), seconds=time.monotonic()-begin)
                            save(leaf/(stem+'.native.json'), receipt)
                    stdout, stderr = (leaf/(stem+'.stdout')).read_text(), (leaf/(stem+'.stderr')).read_text()
                    assert receipt['native_exit'] == 133 and receipt['reaped']
                    trace = tracefmt.read_trace(str(path))
                    check_trace_shape(trace, mode)
                    precise_gp(stdout, symbols[case]['hot_probe'])
                    assert not native.FATAL.search(stdout) and not native.FATAL.search(stderr)
                    # The "--l1-axi selected default --quiesce" banner is
                    # intentionally absent when --quiesce is explicit. Require
                    # actual L1/backend transactions, not that optional banner.
                    require_backend_activity(stdout)
                    footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) after (\d+) retired in (\d+) clocks$', stderr, re.M)
                    assert len(footer) == 1 and int(footer[0][0]) == len(trace.records)
                    counts.append(int(footer[0][1]))
                    paired = None
                    if mode == 'cycle-func':
                        native.grade_native(trace, stdout, stderr, receipt['native_exit'], 133, 2000)
                        functional_pcs = [row['pc'] for row in trace.records]
                    else:
                        assert [row['pc'] for row in trace.records] == functional_pcs
                        paired = pair_witness(trace.records, symbols[case])
                    key = latency, mode
                    if label == 'parent': records[key] = trace.records
                    else: assert records[key] == trace.records, (case, latency, mode, 'full-state/cycle mismatch')
                    rows.append(dict(model=label, latency=latency, mode=mode,
                        records=len(trace.records), clocks=counts[-1], paired_v=None if paired is None else len(paired),
                        trace_sha256=sha(path), native=receipt))
                    assert shutil.disk_usage(scratch).free > 4*1024**3
                assert counts[0] == counts[1]
        result = dict(case=case, passed=True, rows=rows)
        save(leaf/'closed.json', result)
        return result

    begin, rows, errors = time.monotonic(), [], []
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [(case, pool.submit(one, (index, case))) for index, case in enumerate(CASES)]
        for case, future in futures:
            try: rows.append(future.result())
            except Exception as error:
                errors.append(dict(case=case, error=repr(error), traceback=traceback.format_exc()))
    events = dict((k, int(v)) for k,v in (line.split() for line in (group/'memory.events').read_text().splitlines()))
    stable = all(sha(path) == digest for path,digest in pins.items())
    passed = len(rows) == 8 and not errors and stable and not any(events[k] for k in ('oom', 'oom_kill', 'oom_group_kill'))
    result = dict(passed=passed, rows=rows, errors=errors, pins_unchanged=stable, seconds=time.monotonic()-begin,
        memory_events=events, peak_memory=int((group/'memory.peak').read_text()), original_gate_passed=False,
        qemu_differential=False, standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    save(root/'closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k != 'rows'}), flush=True)
    return int(not passed)


if __name__ == '__main__': raise SystemExit(main())
