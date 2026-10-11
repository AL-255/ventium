#!/usr/bin/env python3
"""Bounded native CSR-ownership microgate; no Vivado, CPU build or guest.

Run with one actual CPU, <=512 MiB, zero swap and <=32 tasks in a retained
systemd service. Supply a fresh empty output below the external TMPDIR.
This does not qualify the wrapper, PS service, OS driver or physical FPGA.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import types

REPO = Path(__file__).resolve().parents[1]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--overlay', type=Path)
    args = parser.parse_args()
    assert __debug__
    scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch == Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 2 * 1024**3
    root = args.output.resolve(strict=True)
    assert root.parent == scratch and not list(root.iterdir())
    assert len(os.sched_getaffinity(0)) == 1
    invocation = os.environ['INVOCATION_ID']
    cg = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().split('::', 1)[1].strip().lstrip('/')
    assert 0 < int((cg / 'memory.max').read_text()) <= 512 * 1024**2
    assert (cg / 'memory.swap.max').read_text().strip() == '0'
    assert 0 < int((cg / 'pids.max').read_text()) <= 32
    root.joinpath('source').mkdir()
    files = [REPO / 'fpga/ven_ps2_mailbox.sv', REPO / 'fpga/tb_ps2_mailbox.sv', Path(__file__)]
    pins = {str(path): sha(path) for path in files}
    overlay, proof = None, None
    if args.overlay is not None:
        overlay = args.overlay.resolve(strict=True)
        proof = json.loads((overlay / 'prepared.json').read_text())
        assert proof['kind'] == 'PS2_MOUSE_CSR_SOURCE_OVERLAY' and proof['counter_bits'] == 32
        assert not proof['physical_board'] and not proof['integrated_candidate'] and not proof['core_rtl_changed']
        assert all(sha(overlay / name) == digest for name,digest in proof['files'].items())
        assert all(sha(path) == digest for path,digest in proof['input_pins'].items())
        assert sha(overlay / 'src/ven_ps2_mailbox.sv') == pins[str(files[0])]
        files.extend([overlay / 'src/ven_mgmt_axil.v', REPO / 'fpga/tb_ps2_mailbox_mgmt.sv',
                      REPO / 'fpga/ven_mgmt_debug_tb.sv', REPO / 'fpga/prepare_ps2_mouse_mailbox.py'])
        pins.update({str(path): sha(path) for path in files})
        pins.update(proof['input_pins'])
        pins[str(overlay / 'prepared.json')] = sha(overlay / 'prepared.json')
        pins.update({str(overlay / name): digest for name,digest in proof['files'].items()})
    for path in files:
        copy = root / 'source' / path.name
        shutil.copyfile(path, copy)
        assert sha(copy) == pins[str(path)]
        pins[str(copy)] = sha(copy)
    tools = {name: str(Path(shutil.which(name)).resolve(strict=True)) for name in ('iverilog', 'vvp')}
    tools['verilator'] = str(Path('/tools/verilator/v5.046/bin/verilator').resolve(strict=True))
    pins.update({path: sha(path) for path in tools.values()})
    source, tb = root / 'source/ven_ps2_mailbox.sv', root / 'source/tb_ps2_mailbox.sv'
    rows = []

    def save(name, value):
        with (root / name).open('x') as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write('\n')

    def events():
        return dict(line.split() for line in (cg / 'memory.events').read_text().splitlines())

    def command(label, argv, expected=0):
        start = time.monotonic()
        with (root / (label + '.log')).open('xb') as log:
            process = subprocess.run(argv, cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=30)
        rows.append({'label': label, 'argv': argv, 'exit': process.returncode,
                     'seconds': time.monotonic() - start})
        assert process.returncode == expected, (label, process.returncode)
        return (root / (label + '.log')).read_text()

    def simulate(label, module, expected=0):
        image = root / (label + '.vvp')
        command(label + '-compile', [tools['iverilog'], '-g2012', '-Wall', '-s', 'tb_ps2_mailbox',
                                    '-o', str(image), str(module), str(tb)])
        return command(label, [tools['vvp'], str(image)], expected)

    save('started.json', {'invocation': invocation, 'pins': pins, 'affinity': sorted(os.sched_getaffinity(0)),
                          'memory_before': events(), 'physical_board': False, 'integrated_candidate': False})
    error, results, integration_results = None, [], {}
    try:
        output = simulate('native', source)
        results = [{'bits': int(b), 'checks': int(c), 'transfers': int(t)} for b, c, t in
                   re.findall(r'PS2-MAILBOX-OK bits=(\d+) checks=(\d+) transfers=(\d+)', output)]
        assert {r['bits'] for r in results} == {2, 32} and len(results) == 2
        assert all(r['checks'] > 40 for r in results) and 'PS2-MAILBOX-ALL-OK profiles=2' in output
        text = source.read_text()
        mutants = {
            'unretained-event': ('if (csr_write) begin',
                                 'if (tx_state == TX_EVENT) tx_state <= TX_IDLE;\n                if (csr_write) begin'),
            'stale-generation': ("csr_wdata == 32'(epoch)", "1'b1"),
            'partial-strobe': ("csr_wstrb != 4'hf", "1'b0"),
            'wrong-rx-ack': ("csr_wdata == 32'(rx_sequence)", "1'b1"),
            'tx-sequence-wrap': ('&& !(&tx_sequence);', ';'),
            'queued-abort-delivered': ('if (cancel_queued) begin\n                        tx_state <= TX_EVENT;\n                        delivered <= 0;',
                                       'if (cancel_queued) begin\n                        tx_state <= TX_EVENT;\n                        delivered <= 1;'),
        }
        for label, (old, new) in mutants.items():
            assert text.count(old) == 1, label
            mutant = root / (label + '.sv')
            mutant.write_text(text.replace(old, new))
            pins[str(mutant)] = sha(mutant)
            rejected = simulate(label, mutant, 1)
            assert 'PS2-MAILBOX-FAIL' in rejected and 'test timeout' not in rejected, label
        for bits in (1, 33):
            label = 'invalid-bits-' + str(bits)
            image = root / (label + '.vvp')
            command(label + '-compile', [tools['iverilog'], '-g2012', '-s', 'ven_ps2_mailbox',
                                        '-Pven_ps2_mailbox.COUNTER_BITS=' + str(bits), '-o', str(image), str(source)])
            rejected = command(label, [tools['vvp'], str(image)], 1)
            assert 'COUNTER_BITS must be 2..32' in rejected
        for top, path in [('ven_ps2_mailbox', source)] + (
                [('ven_mgmt_axil', root / 'source/ven_mgmt_axil.v')] if overlay else []):
            command(top + '-lint', [tools['verilator'], '--lint-only', '-sv', '-Wall', '-Wno-UNUSED',
                    '-Wno-fatal', *['-Werror-' + name for name in
                    ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                    '--top-module', top, str(path)])
        if overlay:
            recipe_path = root / 'source/prepare_ps2_mouse_mailbox.py'
            recipe = types.ModuleType('frozen_mouse_recipe')
            recipe.__file__ = str(recipe_path)
            exec(compile(recipe_path.read_bytes(), str(recipe_path), 'exec'), recipe.__dict__)
            checks = 0
            for name, transform in (('src/ven_mgmt_axil.v', recipe.management),
                                    ('src/rk_ao486_system_pl.v', recipe.wrapper),
                                    ('hw/create_project.tcl', recipe.project)):
                matches = [Path(p) for p,h in proof['input_pins'].items()
                           if p.endswith('/' + name) and h == recipe.BASE[name]]
                assert len(matches) == 1
                original = matches[0].read_text()
                assert transform(original) == (overlay / name).read_text()
                checks += 1
                for bad in ('', original + original, (overlay / name).read_text()):
                    try:
                        transform(bad)
                    except ValueError:
                        checks += 1
                    else:
                        raise AssertionError('recipe accepted missing/duplicate/repeated transformation')
            integration_results['recipe_checks'] = checks
            management = root / 'source/ven_mgmt_axil.v'

            def mgmt_run(label, module, top, expected=0):
                image = root / (label + '.vvp')
                command(label + '-compile', [tools['iverilog'], '-g2012', '-Wall', '-s', top,
                    '-o', str(image), str(module), str(source), str(root / 'source' / (top + '.sv'))])
                return command(label, [tools['vvp'], str(image)], expected)

            text = mgmt_run('management-native', management, 'tb_ps2_mailbox_mgmt')
            assert 'PS2-MGMT-OK checks=233 native_transfers=1 command_pulses=14' in text
            integration_results['management_checks'] = 233
            assert 'VEN-MGMT-DEBUG-TB-OK' in mgmt_run('legacy-debug', management, 'ven_mgmt_debug_tb')
            original = management.read_text()
            for label, old, new in (
                    ('lost-strobes', 'mouse_csr_wstrb <= s_wstrb;', "mouse_csr_wstrb <= 4'hf;"),
                    ('wrong-read-index', 'mouse_csr_raddr = s_araddr[7:4];', 'mouse_csr_raddr = s_araddr[6:3];'),
                    ('repeated-submit', '            mouse_csr_write<=0;\n', '')):
                assert original.count(old) == 1
                mutant = root / (label + '.v')
                mutant.write_text(original.replace(old, new))
                pins[str(mutant)] = sha(mutant)
                rejected = mgmt_run(label, mutant, 'tb_ps2_mailbox_mgmt', 1)
                assert 'PS2-MGMT-FAIL' in rejected and 'test timeout' not in rejected
            integration_results['management_mutants_rejected'] = 3
    except Exception as exc:
        error = repr(exc)
    stable = all(sha(path) == digest for path, digest in pins.items())
    after = events()
    passed = error is None and stable and all(after.get(key) == '0' for key in ('oom', 'oom_kill', 'oom_group_kill'))
    value = {'passed': passed, 'error': error, 'results': results, 'integration': integration_results, 'commands': rows,
             'pins': pins, 'pins_unchanged': stable, 'invocation': invocation, 'memory_after': after,
             'memory_peak': int((cg / 'memory.peak').read_text()), 'physical_board': False,
             'integrated_candidate': False, 'standard_suite': False, 'gameplay_ipc': None}
    save('closed.json', value)
    print(json.dumps({'passed': passed, 'error': error, 'evidence': str(root), 'results': results}), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
