"""Grade retained physical CoreMark evidence; read-only on the board.

No benchmark launch, reprogramming, clock adjustment, or general CPU acceptance.
The image's independent native/source audit remains a separate prerequisite.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys

import decode_coremark_screen as screen

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/bench/coremark_boot'))
sys.path.insert(0, str(REPO/'fpga/board-tools'))
from check_result import check
from ven_ipc_window import interval


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def paired_lower_bound(samples, primary_at_reset):
    """Conservative CURRENT trial witness, never inherit prior runs' V count.

    Total is sampled between U_before and U_after. Subtract the largest U delta
    from the measured total delta. Historical samples without U_before use the
    earlier held-reset U observation, which only makes the lower bound smaller.
    """
    first,last=samples[0],samples[-1]
    first_u=first.get('primary_retirements_before',primary_at_reset)
    last_u=last['primary_retirements_after']
    if not primary_at_reset <= first_u <= last_u:
        raise ValueError('primary counter reset or invalid order')
    total_delta=last['total_retirements']-first['total_retirements']
    if total_delta < 0:
        raise ValueError('total counter reset')
    return total_delta-(last_u-first_u)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--trial', type=Path, required=True)
    parser.add_argument('--remote-trial', required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--seed', choices=['performance', 'validation'], required=True)
    parser.add_argument('--unit', required=True)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--firmware', required=True)
    parser.add_argument('--rom', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    def read(name): return json.loads((args.trial/name).read_text())
    def remote(argv):
        return subprocess.check_output(['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=10', 'riguke@rk-xczu15eg-f.local', shlex.join(argv)],
            text=True, timeout=30)
    start, closed, clock = read('started.json'), read('closed.json'), read('held-clock.json')
    assert closed['console_complete'] and not closed['errors'] and closed['inputs_unchanged']
    assert closed['daemon_stopped_by_controller'] and closed['daemon_exit'] == -15
    assert closed['guest_reset_and_posted_drain_verified'] and read('held-after.json')['held_reset']
    assert start['no_step'] and start['no_snapshot']
    owner = dict(line.split('=', 1) for line in remote(['systemctl', 'show', args.unit,
        '-p', 'MainPID', '-p', 'InvocationID', '-p', 'ExecMainStatus', '-p', 'SubState']).splitlines())
    assert owner == dict(MainPID='0', InvocationID=start['invocation'], ExecMainStatus='0', SubState='exited'), owner
    # Reconcile EVERY retained trial file against the closed board originals.
    local = {p.name:sha(p) for p in args.trial.iterdir() if p.is_file()}
    remote_hashes = remote(['sha256sum', '--'] + [str(Path(args.remote_trial)/n) for n in sorted(local)])
    for line in remote_hashes.splitlines():
        digest, name = line.split(None, 1)
        assert local[Path(name).name] == digest
    image_sha = sha(args.image)
    assert remote(['sha256sum', '--', args.firmware]).split()[0] == image_sha
    for path, digest in start['pins'].items():
        name = Path(path).name
        if name.endswith('.py'):
            source = REPO/'fpga'/name if name == 'decode_coremark_screen.py' else REPO/'fpga/board-tools'/name
            assert sha(source) == digest, source
    reference = json.loads(args.reference.read_text())
    assert reference['passed'] and not reference['errors']
    row, = [row for row in reference['rows'] if row['seed'] == args.seed]
    assert row['command']['native_exit'] == 33
    media_pin, = [value for path,value in start['pins'].items() if path.endswith('/coremark.img')]
    assert media_pin == row['disk_sha256']
    raw = args.trial/f"frame-{closed['captured_frames']-1:03d}.vcap"
    pixels, meta = screen.frame(raw.read_bytes())
    decoded = screen.decode(pixels, meta['width'], meta['height'],
        screen.font(args.rom.read_bytes(), meta['width']//80))
    console = (args.trial/'console.txt').read_text()
    assert decoded['exact_glyphs'] and decoded['text'] == console
    assert row['iterations'] in (2000,4000)
    result = check(console, reference_crcs=row['crcs'], iterations=row['iterations'], require_valid_duration=True)
    assert clock['retirements_delta'] == 0 and clock['guard_checks'] >= 80 and clock['debug_abi'] == 5
    assert clock['expected_core_mhz'] == start['expected_mhz']
    duration = result['ticks'] / (clock['measured_core_mhz'] * 1e6)
    minimum_duration = result['ticks'] / (clock['upper_mhz'] * 1e6)
    assert minimum_duration >= 10
    samples = [json.loads(line) for line in (args.trial/'samples.jsonl').read_text().splitlines()]
    assert len(samples) >= 20
    for before, after in zip(samples, samples[1:]):
        interval(before, after)
        assert after['primary_retirements_after'] >= before['primary_retirements_after']
    paired_lower = paired_lower_bound(samples,clock['before']['retired'])
    assert paired_lower > 1_000_000
    if start.get('runtime_pll'):
        divider=start['pll_divider']
        assert clock['allow_previous_retirements'] and not start['reprogrammed']
        assert abs(1000/divider-start['expected_mhz'])<1e-6
        change=read('pll-change.json')
        assert change['requested_divider']==divider and not change['reprogrammed']
        assert read('held-before-clock.json')['held_reset']
        for status in [change['after'],read('pll-after.json')]+[s['pll'] for s in samples]:
            assert status['divider']==divider and status['locked'] and status['clock_enabled']
            assert not status['busy'] and not status['error'] and not status['mmcm_reset']
    final = read('final-state.json')
    assert not final['freeze']['frozen'] and final['execution']['raw'] == '00000000'
    result.update(physical_coremark_trial_pass=True, measured_mhz=clock['measured_core_mhz'],
        duration_seconds=duration, conservative_duration_seconds=minimum_duration,
        coremark_per_mhz=result.pop('diagnostic_ratio'), paired_retirements_lower_bound=paired_lower,
        primary_u_observation=samples[-1]['primary_retirements_after'],
        total_uv_observation=samples[-1]['total_retirements'], sample_count=len(samples),
        image_sha256=image_sha, native_owner=owner, retained_file_hashes=local,
        gameplay_ipc=None, timing_signoff=False, highest_clock_qualified=False,
        audit_script_sha256=sha(__file__))
    with args.out.open('x') as stream: json.dump(result, stream, indent=2)
    print(json.dumps({k:v for k,v in result.items() if k != 'retained_file_hashes'}, indent=2))


if __name__ == '__main__': main()
