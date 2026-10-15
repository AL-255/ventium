"""Independent read-only closure of the older repaired-model Quake timedemo.

Recheck the original completion checker against the closed disk/log, native
ownership and pinned input receipts. Never qualify newer timing RTL or FPGA.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

MODEL = 'c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def main():
    assert __debug__
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    root = scratch/'ventium-fp-repair-transfer.a8nzrjHu'
    soc = root/'soc-r1'; case = soc/'quake-cold-fp-repair-oct13.1'; run = case/'run'
    owner = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', 'ventium-fp-repair-quake-oct13.service',
        '-pMainPID', '-pSubState', '-pExecMainStatus', '-pInvocationID'], text=True).splitlines())
    assert owner == dict(MainPID='0', SubState='exited', ExecMainStatus='0',
                         InvocationID='56b52d8499764820923836107f97ffd2')
    result, canonical, capture, admission, inputs, resources = [load(p) for p in (
        case/'result.json', run/'result.json', run/'capture.json', case/'native-admission.json',
        run/'inputs.json', case/'receipt-final.json')]
    assert result['status'] == canonical['status'] == 'PASS' and result['error'] is None
    assert result['canonical_result'] == canonical and result['canonical_runner_returncode'] == 0
    assert sha(run/'result.json') == result['canonical_result_sha256']
    assert sha(case/'receipt-final.json') == result['final_resource_receipt_sha256']
    assert resources['no_oom'] and resources['invocation_id'] == owner['InvocationID']
    assert all(dict(line.split() for line in resources['cgroup_files']['memory.events'].splitlines())[k] == '0'
               for k in ('oom', 'oom_kill', 'oom_group_kill'))
    assert result['input_and_archives_unchanged']
    pins = dict(result['input_sha256_after'])
    assert all(sha(p) == h for p, h in pins.items())
    assert admission['exe_sha256'] == inputs['binary_sha256'] == result['candidate_sha256'] == MODEL
    assert admission['affinity'] == [11] and admission['argv'] == inputs['command'][3:]
    assert inputs['command'][:3] == ['taskset', '-c', '11']
    assert inputs['cold_reset'] and not inputs['snapshots'] and not inputs['guest_modifications']
    assert inputs['FPGA_DDR'] == 3
    command = admission['argv']
    assert not {'--restore', '--step', '--break-eip', '--kb'} & set(command)
    for key, value in (('--rate', '40000000'), ('--rate-rtc', '40000000'),
                       ('--rate-vga', '80000000'), ('--mem', '16')):
        assert command[command.index(key)+1] == value
    assert not Path('/proc', str(admission['pid'])).exists(), 'old native PID now reused; inspect identity'
    assert canonical['process_group_absent_after_wait'] and canonical['sim_returncode'] == 0
    assert canonical['log_capture'] == capture and capture['actual_child_wait'] and capture['pipe_eof']
    assert capture['sim_returncode'] == 0 and capture['sticky_error'] is None
    log = (run/'run.log').read_bytes()
    assert len(log) == capture['captured_bytes'] == capture['persisted_bytes'] < capture['byte_limit']
    assert sha(run/'run.log') == capture['sha256'] == '4b6a633f9f4277a4387ac3b3b95fdcf6bfa4d1166b4a7afa8e4bf0f8cc898fd8'
    assert (run/'stop.request').read_bytes() == b'fresh timedemo observed; close disk for final checking\n'
    # This is the original Quake runner's regular-file stop protocol. Do not
    # silently impose or waive the different Win95 checker's empty-file policy.
    checker = soc/'cold-helpers/check_quake_timedemo.py'
    assert sha(checker) == '427d9e7471eb4d6a65361fc468646307c66df4fe70fe8001e51977307bb85ad7'
    spec = importlib.util.spec_from_file_location('quake_closed', checker)
    gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
    checked = gate.check(run/'guest.vhd', load(run/'baseline.json'), log, stopped=True, returncode=0)
    assert all(canonical[k] == v for k, v in checked.items()) and checked['status'] == 'PASS'
    assert checked['disk_sha256'] == result['closed_private_disk_sha256']
    assert checked['result'] == dict(frames=969, seconds='125.4', fps='7.7')
    provenance = load(run/'python-provenance.json')
    assert provenance['loaded_function_code_before'] == provenance['loaded_function_code_after']
    for record in provenance['sources'].values():
        assert record['canonical_source_unchanged']
        assert sha(record['source']) == sha(record['archive']) == record['sha256_before']
    built = load(soc/'build-closed.json'); before = load(soc/'build-started.json')
    assert built['passed'] and built['inputs_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == MODEL
    source_pins = {p: h for p, h in before['pins'].items() if Path(p).is_relative_to(soc/'source')}
    assert source_pins and all(sha(p) == h for p, h in source_pins.items())
    pins.update(source_pins)
    defs = set((soc/'defines.txt').read_text().splitlines())
    assert len(defs) == 156 and {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_L1_AXI'} <= defs
    assert not {'VEN_CACHE_HALF', 'VEN_SYS_FASTPATH_ALL'} & defs
    shim = soc/'source/ao486-sim/ven/ven_ao486_shim.sv'
    assert re.search(r'\.cycle_mode\s*\(1\x27b1\)', shim.read_text())
    rows = []
    for line in log.decode().splitlines():
        match = re.fullmatch(r'\[VEN-PERF\] cycle=(\d+) retires=(\d+) clocks=(\d+) u=(\d+) v=(\d+) .+', line)
        if match and int(match[1]) in (5600065237, 5700065237):
            rows.append(dict(zip(('cycle', 'retirements', 'clocks', 'u', 'v'), map(int, match.groups()))))
    assert [r['cycle'] for r in rows] == [5600065237, 5700065237]
    assert all(r['retirements'] == r['u']+r['v'] for r in rows)
    delta = {k: rows[1][k]-rows[0][k] for k in rows[0]}
    assert delta == dict(cycle=100000000, retirements=50520554, clocks=100000000, u=38885286, v=11635268)
    frames = {'frame_00051.ppm': '162105a9e25d41ba764d7f9c991fcecbc83f34bfd1cff23212ce93eb3cacf6dc',
              'frame_00052.ppm': 'b170f7e4e4006cbaec545dba36a33a196a6c847b81a6416cb549286e6f47131d'}
    for name, digest in frames.items():
        assert sha(run/name) == digest
        pins[str(run/name)] = digest
    for p in (Path(__file__), checker, case/'result.json', run/'result.json', run/'capture.json',
              case/'native-admission.json', run/'inputs.json', case/'receipt-final.json',
              run/'baseline.json', run/'python-provenance.json', run/'run.log', run/'stop.request',
              soc/'build-started.json', soc/'build-closed.json', soc/'defines.txt'):
        pins[str(p)] = sha(p)
    audit = dict(passed=True, owner=owner, model=MODEL, cold_timedemo=checked,
        artifact_pins=pins, source_files_rechecked=len(source_pins), native_affinity=admission['affinity'],
        log_integrity_rechecked=True, inputs_unchanged=True, no_oom=True, rows=rows, delta=delta,
        gameplay_uv_ipc=delta['retirements']/delta['clocks'], frames_as_is=frames,
        visual_review='Frame 51: gold-key message, weapon/HUD; frame 52: approaching exit portal, weapon/HUD. Both are gameplay, not loading. No color adjustment.',
        gameplay_window_not_whole_timedemo_average=True, current_timing_candidate=False,
        current_candidate_gameplay_ipc=None, physical_fpga=False, standard_suite=False)
    with (root/'quake-closed-audit.json').open('x') as stream:
        json.dump(audit, stream, indent=2)
    print(json.dumps({k: v for k, v in audit.items() if k != 'artifact_pins'}, indent=2))


if __name__ == '__main__':
    main()
