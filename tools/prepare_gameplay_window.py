#!/usr/bin/env python3
"""Prepare a predeclared cold-Quake window; never grant visual/suite acceptance.

Uses periodic sample indices, not guessed exact timestamps or a best-IPC window.
The simulator remains running and unmodified. Review both pixel-identical PNGs
separately before calling the result verified gameplay. A complete timedemo is
an independent requirement.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

import cpi_interval as cpi


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def select_window(lines, indices, width):
    if (len(indices) != 2 or any(type(n) is not int or n < 1 for n in indices)
            or indices[1] != indices[0] + 1 or width <= 0):
        raise ValueError('require two adjacent positive periodic indices')
    cycles = [int(m[1]) for line in lines
              if (m := re.search(r'\[VEN-PERF\] cycle=(\d+)\b', line))]
    if len(cycles) < indices[1]:
        raise ValueError(f'window not ready: {len(cycles)} samples, need {indices[1]}')
    # The first sample is approximately one period after reset, with a fixed
    # scheduler offset. Do not interpolate that offset away or skip samples.
    if not width <= cycles[0] < 2 * width:
        raise ValueError('log does not begin at first periodic sample')
    if any(b - a != width for a, b in zip(cycles, cycles[1:])):
        raise ValueError('periodic sample missing, duplicated or restarted')
    start, end = (cycles[i - 1] for i in indices)
    first, last = cpi.samples(lines, start, end)
    if (first['cycle'], last['cycle']) != (start, end):
        raise ValueError('selected endpoint missing')
    delta = cpi.delta(first, last)
    cpi.validate_profile(delta, is_delta=True)
    if delta['cycle'] != width or delta['v'] == 0:
        raise ValueError('wrong width or no actual V retirement')
    return first, last, delta


def frame_bounds(lines, ppm, cycle):
    hits = [i for i, line in enumerate(lines)
            if line.startswith('[FBCAP] ' + str(ppm) + ' ')]
    if len(hits) != 1:
        raise ValueError('missing or ambiguous endpoint capture')
    i = hits[0]
    previous = next((cpi.PROGRESS.match(s) for s in reversed(lines[:i])
                     if cpi.PROGRESS.match(s)), None)
    following = next((cpi.PROGRESS.match(s) for s in lines[i + 1:]
                      if cpi.PROGRESS.match(s)), None)
    if previous is None or following is None:
        raise ValueError('capture lacks both progress brackets')
    bounds = [int(previous[1]), int(following[1])]
    if not bounds[0] <= cycle <= bounds[1] or not 0 < bounds[1] - bounds[0] <= 500000:
        raise ValueError('capture does not bracket the selected endpoint')
    return bounds


def stable_file(path):
    before = path.stat()
    digest = sha(path)
    after = path.stat()
    if (before.st_ino, before.st_dev, before.st_size, before.st_mtime_ns) != (
            after.st_ino, after.st_dev, after.st_size, after.st_mtime_ns):
        raise ValueError('artifact changed while reading: ' + str(path))
    return digest


def main():
    assert __debug__, 'validation must not run with Python optimization enabled'
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('build', 'run', 'out'):
        ap.add_argument('--' + name, type=Path, required=True)
    args = ap.parse_args()
    build, run = args.build.resolve(strict=True), args.run.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert args.out.resolve().is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch and not args.out.exists()
    plan_path = build / 'gameplay-plan.json'
    plan = json.loads(plan_path.read_text())
    source = json.loads((build / 'build-started.json').read_text())
    closed = json.loads((build / 'build-closed.json').read_text())
    before = json.loads((run / 'receipt-before.json').read_text())
    native = json.loads((run / 'native-admission.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged']
    assert plan['predeclared_before_gameplay'] and plan['not_full_timedemo_acceptance']
    assert plan['model_sha256'] == closed['binary_sha256'] == native['exe_sha256']
    unit = native['cgroup'].split('/')[-1]
    invocation = before['invocation_id']
    if 'invocation_id' in plan:
        assert plan['invocation_id'] == invocation
    else:
        assert plan['required_service'] == unit
        admission = json.loads((build / 'admission-audit.json').read_text())
        assert admission['passed'] and admission['gameplay_invocation'] == invocation
        assert admission['gameplay_plan_sha256'] == sha(plan_path)
    pins = dict(source['pins'])
    pins.update(before['input_sha256_before'])
    pins.update({str(p): stable_file(p) for p in (
        plan_path, build / 'build-started.json', build / 'build-closed.json',
        run / 'receipt-before.json', run / 'native-admission.json',
        Path(__file__).resolve(), Path(cpi.__file__).resolve())})
    assert all(stable_file(Path(p)) == digest for p, digest in pins.items())
    assert sha(native['exe']) == native['exe_sha256']
    proc = Path('/proc') / str(native['pid'])
    assert (proc / 'exe').resolve() == Path(native['exe'])
    assert int((proc / 'stat').read_text().rsplit(')', 1)[1].split()[19]) == native['starttime']
    assert (proc / 'cmdline').read_bytes().rstrip(b'\0').split(b'\0') == [s.encode() for s in native['argv']]
    assert os.sched_getaffinity(native['pid']) == set(native['affinity'])
    observation = subprocess.check_output(['systemctl', '--user', 'show', unit,
        '-p', 'InvocationID', '-p', 'ActiveState', '-p', 'MainPID'], text=True)
    owner = dict(line.split('=', 1) for line in observation.splitlines())
    assert owner['InvocationID'] == invocation and owner['ActiveState'] == 'active'
    assert int(owner['MainPID']) == native['ppid'] == before['worker']['pid']
    cg = Path('/sys/fs/cgroup') / native['cgroup'].split('::', 1)[1].lstrip('/')
    events = dict(line.split() for line in (cg / 'memory.events').read_text().splitlines())
    assert events['oom'] == events['oom_kill'] == '0'
    # Take a bounded prefix of an append-only log. Ignore only its final
    # unfinished line, never a malformed complete profiler record.
    log_path = run / 'run/run.log'
    with log_path.open('rb') as stream:
        data = stream.read(os.fstat(stream.fileno()).st_size)
    data = data[:data.rfind(b'\n') + 1]
    lines = data.decode().splitlines()
    assert not re.search(r'%Error|%Fatal|Assertion failed|RETIRE-STOP-FAIL|SNAPSHOT-ERROR', data.decode())
    first, last, delta = select_window(lines, plan['sample_indices'], plan['window_width_cycles'])
    frames = []
    assert len(plan['endpoint_frame_indices']) == 2
    for index, counter in zip(plan['endpoint_frame_indices'], (first, last), strict=True):
        ppm = run / f'run/frame_{index:05d}.ppm'
        frames.append(dict(ppm=str(ppm), ppm_sha256=stable_file(ppm),
            adjacent_progress_cycle_bounds=frame_bounds(lines, ppm, counter['cycle']),
            associated_counter_cycle=counter['cycle']))
    args.out.mkdir()
    for frame in frames:
        ppm = Path(frame['ppm'])
        png = args.out / (ppm.stem + '.png')
        subprocess.run(['ffmpeg', '-nostdin', '-n', '-v', 'error', '-i', str(ppm),
                        '-frames:v', '1', str(png)], check=True, timeout=30)
        def pixels(path):
            return subprocess.check_output(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(path),
                '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], timeout=30)
        assert pixels(ppm) == pixels(png) and stable_file(ppm) == frame['ppm_sha256']
        frame.update(png=str(png.resolve()), png_sha256=stable_file(png))
    assert all(stable_file(Path(p)) == digest for p, digest in pins.items())
    record = dict(model_sha256=native['exe_sha256'], invocation_id=invocation,
        pid=native['pid'], native=native, source_inputs_rechecked=len(source['pins']),
        runtime_inputs_rechecked=len(before['input_sha256_before']), pins=pins,
        first=first, last=last, delta=delta, sample_indices=plan['sample_indices'],
        retirement_event_ipc=delta['retires']/delta['cycle'], gameplay_ipc=None,
        frames=frames, raw_pixels_preserved=True, endpoint_frames_reviewed_as_gameplay=False,
        no_oom=True, full_timedemo=False, standard_suite=False,
        log_prefix_bytes=len(data), log_prefix_sha256=hashlib.sha256(data).hexdigest(),
        note='Requires independent endpoint visual review and UV/fast-mode audit; not suite acceptance.')
    with (args.out / 'prepared.json').open('x') as stream:
        json.dump(record, stream, indent=2)
    print(json.dumps(dict(prepared=True, gameplay_ipc=None, model=record['model_sha256'],
                         cycles=[first['cycle'], last['cycle']], frames=frames), indent=2))


if __name__ == '__main__':
    main()
