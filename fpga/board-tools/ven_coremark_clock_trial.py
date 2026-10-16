#!/usr/bin/env python3
"""Bounded physical CoreMark trial using an already programmed image.

No programming, guest patch, snapshot, STEP or breakpoint. --pll-divider opts
into runtime PLL control and repeated cold boots of the SAME programmed image.
The caller pins/programs the bitstream and separately grades CRCs and duration.
The only run controls are cold initialization, one RUN, and reset after evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import time

import ven_board_probe as probe
from ven_cold_clock import measure
from ven_ipc_window import sample
from ven_uv_fast_guard import require_running
import decode_coremark_screen as screen

DAEMON = Path('/tmp/ao486/ao486d.posted-safe-oct08')
DAEMON_SHA = '085c629bf84039f0dfd1983b9909026f0e18a811cf43730b68fb9d74357ee4d3'
BOOT0_SHA = 'dca915c5483793a710ee118c5232aad01ef3191bea7d50c2befb1a47d2dd26a3'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def no_daemon():
    for process in Path('/proc').iterdir():
        if not process.name.isdecimal():
            continue
        try:
            executable = (process/'exe').resolve(strict=True)
        except (FileNotFoundError, PermissionError):
            continue
        if executable.name.startswith('ao486d'):
            raise RuntimeError(f'active board daemon: PID {process.name} {executable}')


def quiesce(ctrl, *, api=probe, sleep=time.sleep):
    """Hold reset and observe real posted DDR completion; no cancellation."""
    api.require_exec_debug(ctrl)
    previous = api.u32(ctrl, api.R_DBG_ARCH_SEL)
    if previous > 127:
        raise ValueError('invalid original selector')
    struct.pack_into('<I', ctrl, 0x20, 1)
    struct.pack_into('<I', ctrl, api.R_DBG_ARCH_SEL, 79)
    clean = 0
    try:
        for attempt in range(1000):
            sleep(.001)
            if api.u32(ctrl, 0x20) != 1 or api.u32(ctrl, api.R_DBG_ARCH_SEL) != 79:
                raise ValueError('reset/scan ownership changed')
            status = api.u32(ctrl, api.R_DBG_ARCH_DATA)
            if status & ~7 != 0x50440000 or not status & 2 or status & 4:
                raise ValueError(f'unsupported/faulted posted DDR: {status:08x}')
            clean = clean+1 if status & 1 else 0
            if clean == 2:
                return dict(held_reset=True, posted_status=f'{status:08x}', polls=attempt+1)
        raise TimeoutError('posted DDR did not drain')
    finally:
        if api.u32(ctrl, api.R_DBG_ARCH_SEL) == 79:
            struct.pack_into('<I', ctrl, api.R_DBG_ARCH_SEL, previous)


def thermal():
    paths=list(Path('/sys/class/thermal').glob('thermal_zone*/temp'))
    paths+=list(Path('/sys/bus/iio/devices').glob('iio:device*/in_temp*_input'))
    return {str(p):p.read_text().strip() for p in paths}


def run(args):
    out = args.out.resolve()
    if not str(out).startswith('/dev/shm/ventium-coremark-clock-stage.') or out.exists():
        raise ValueError('require a new trial leaf inside the private board staging directory')
    if not 20 <= args.expected_mhz <= 100 or not 30 <= args.seconds <= 180:
        raise ValueError('trial bounds invalid')
    if args.pll_divider is not None and (not 10 <= args.pll_divider <= 50 or
            abs(1000/args.pll_divider-args.expected_mhz)>1e-6):
        raise ValueError('expected clock must match the explicit runtime PLL divider')
    no_daemon()
    if sha(DAEMON) != DAEMON_SHA or sha('/tmp/ao486/boot0.rom') != BOOT0_SHA:
        raise ValueError('daemon/BIOS identity mismatch')
    if sha('/tmp/ao486/boot1.rom') != screen.ROM_SHA or sha(args.media) != args.media_sha:
        raise ValueError('VGA BIOS/media identity mismatch')
    if args.media.is_symlink() or args.media.stat().st_nlink != 1:
        raise ValueError('requires a private single-link disk')
    # The daemon independently refuses System RAM overlap before DDR mapping.
    # Retain the unmasked root memory map and DT tuple for this boot, too.
    node = Path('/proc/device-tree/reserved-memory/guest-ram@60000000')
    if (node/'reg').read_bytes() != struct.pack('>QQ', 0x60000000, 0x10000000):
        raise ValueError('unexpected guest DDR reservation')
    if not (node/'no-map').exists() or (node/'reusable').exists():
        raise ValueError('guest DDR is not exclusively reserved')
    for name in ('#address-cells', '#size-cells'):
        if (node.parent/name).read_bytes() != struct.pack('>I', 2):
            raise ValueError('unexpected reserved-memory cell widths')
    out.mkdir()
    def save(name, value):
        with (out/name).open('x') as stream:
            json.dump(value, stream, indent=2)
    helpers = list(Path(__file__).resolve().parent.glob('*.py'))
    pins = {str(p):sha(p) for p in helpers + [DAEMON, Path('/tmp/ao486/boot0.rom'),
                                               Path('/tmp/ao486/boot1.rom'), args.media]}
    save('started.json', dict(pins=pins, expected_mhz=args.expected_mhz,
        boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
        iomem=Path('/proc/iomem').read_text(), thermal=thermal(), label=args.label,
        invocation=os.environ.get('INVOCATION_ID'), controller_pid=os.getpid(),
        no_step=True, no_snapshot=True, acceptance=False,
        runtime_pll=args.pll_divider is not None, pll_divider=args.pll_divider,
        reprogrammed=False))
    fd, ctrl, _ = probe.open_mmio(writable=True)
    child = None
    errors = []
    completed = False
    captured = 0
    stopped_by_controller = False
    reset_drained = False
    pll = None
    try:
        if args.pll_divider is not None:
            import ven_pll_clock
            pll = ven_pll_clock.GpioMailbox()
            save('held-before-clock.json', quiesce(ctrl))
            save('pll-change.json',ven_pll_clock.change(pll,args.pll_divider))
        held_clock=measure(ctrl, expected_mhz=args.expected_mhz,
                           allow_previous_retirements=pll is not None)
        save('held-clock.json',held_clock)
        probe.prepare_cold_probe(argparse.Namespace(
            held_primary_retirements=held_clock['after']['retired']))
        with (out/'daemon.stdout').open('xb') as stdout, (out/'daemon.stderr').open('xb') as stderr:
            argv = [str(DAEMON), '--membase', '0x60000000', '--mem', '16',
                    '--bios', '/tmp/ao486', '--hdd', str(args.media), '--secs', str(args.seconds)]
            child = subprocess.Popen(argv, stdout=stdout, stderr=stderr, start_new_session=True)
            save('daemon-owner.json', dict(pid=child.pid, argv=argv, executable=str(Path(f'/proc/{child.pid}/exe').resolve())))
            deadline = time.monotonic()+30
            while 'x86_init done;' not in (out/'daemon.stderr').read_text():
                if child.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('daemon failed/expired during cold initialization')
                time.sleep(.1)
            initial = probe.read_halted_arch_state(ctrl)
            save('before-release.json', initial)
            if initial['cs'] != 'f000' or initial['eip'] != '0000fff0':
                raise ValueError('not the cold reset vector')
            probe.run_probe(argparse.Namespace(timeout=2))
            deadline = time.monotonic()+args.seconds
            capture_at = time.monotonic()+3
            with (out/'samples.jsonl').open('x') as samples:
                while time.monotonic() < deadline:
                    if child.poll() is not None:
                        raise RuntimeError('daemon exited before complete CoreMark console')
                    primary_before = probe.stable_u64(ctrl, probe.R_DBG_RET_LO, probe.R_DBG_RET_HI)
                    record = sample(lambda off:probe.u32(ctrl, off),
                                    lambda off,value:struct.pack_into('<I', ctrl, off, value))
                    record['primary_retirements_before'] = primary_before
                    record['primary_retirements_after'] = probe.stable_u64(ctrl, probe.R_DBG_RET_LO, probe.R_DBG_RET_HI)
                    if pll is not None:
                        state=ven_pll_clock.decode(pll.read())
                        if state['busy'] or state['error'] or not state['locked'] or not state['clock_enabled'] or state['mmcm_reset'] or state['divider']!=args.pll_divider:
                            raise ValueError(f'PLL changed/failed during trial: {state}')
                        record['pll']=state
                    record['monotonic_ns'] = time.monotonic_ns()
                    samples.write(json.dumps(record)+'\n'); samples.flush()
                    if time.monotonic() >= capture_at:
                        seq, cycle, width, height, pixels, payload = probe._capture_scanout_frame(
                            ctrl, frame_timeout=10, poll_interval=.002)
                        raw = (screen.STREAM.pack(b'VENVCAP1', 1, 1) + screen.FRAME.pack(
                            b'VFRM', seq, time.monotonic_ns(), cycle, width, height,
                            pixels, probe.zlib.crc32(payload)&0xffffffff) + payload)
                        with (out/f'frame-{captured:03d}.vcap').open('xb') as stream: stream.write(raw)
                        decoded = screen.decode(payload, width, height,
                            screen.font(Path('/tmp/ao486/boot1.rom').read_bytes(), width//80))
                        save(f'frame-{captured:03d}.json', decoded)
                        captured += 1
                        if decoded['exact_glyphs'] and 'PORT-END\n' in decoded['text']:
                            with (out/'console.txt').open('x') as stream: stream.write(decoded['text'])
                            completed = True
                            break
                        capture_at = time.monotonic()+3
                    time.sleep(.1)
            if not completed:
                raise TimeoutError('no exact complete console by trial deadline')
            require_running(probe.u32(ctrl, probe.R_DBG_EXEC_CTRL), probe.u32(ctrl, probe.R_DBG_FRZINFO),
                            capability=probe.u32(ctrl, probe.R_DBG_EXEC_CAP))
            save('final-state.json', probe.debug_state(ctrl))
    except Exception as error:
        errors.append(repr(error))
    finally:
        if child is not None and child.poll() is None:
            stopped_by_controller = True
            os.killpg(child.pid, signal.SIGTERM)
            try: child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL); child.wait(timeout=10)
        try:
            no_daemon()
            save('held-after.json', quiesce(ctrl))
            reset_drained = True
        except Exception as error: errors.append('quiesce: '+repr(error))
        if pll is not None:
            try: save('pll-after.json',ven_pll_clock.decode(pll.read()))
            except Exception as error: errors.append('PLL cleanup: '+repr(error))
            pll.close()
        ctrl.close(); os.close(fd)
    stable = all(sha(p) == digest for p,digest in pins.items())
    save('closed.json', dict(console_complete=completed, errors=errors,
        inputs_unchanged=stable, captured_frames=captured, thermal=thermal(),
        daemon_exit=None if child is None else child.returncode,
        daemon_stopped_by_controller=stopped_by_controller,
        guest_reset_and_posted_drain_verified=reset_drained,
        acceptance=False, gameplay_ipc=None, needs_host_crc_duration_and_image_audit=True))
    return 0 if completed and not errors and stable else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('quiesce')
    trial = commands.add_parser('run')
    trial.add_argument('--out', type=Path, required=True)
    trial.add_argument('--media', type=Path, required=True)
    trial.add_argument('--media-sha', required=True)
    trial.add_argument('--label', required=True)
    trial.add_argument('--expected-mhz', type=float, required=True)
    trial.add_argument('--seconds', type=int, default=120)
    trial.add_argument('--pll-divider',type=int,
                       help='runtime clock change on the SAME image; enables retained-counter measurements')
    args = parser.parse_args()
    if os.geteuid() != 0: raise PermissionError('board root required')
    if args.command == 'run': return run(args)
    no_daemon()
    fd, ctrl, _ = probe.open_mmio(writable=True)
    try: print(json.dumps(quiesce(ctrl)))
    finally: ctrl.close(); os.close(fd)
    return 0


if __name__ == '__main__': raise SystemExit(main())
