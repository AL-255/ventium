#!/usr/bin/env python3
"""Bounded, lossless host FIFO recording; never timedemo or CPU acceptance.

Run before the board's capture producer. The board root must already contain
the root-owned capture FIFO, readable by riguke. Native producer/guest closure,
image/mode/clock identity and timedemo coverage require separate evidence.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import struct
import subprocess
import time
import zlib

STREAM_HEADER = struct.Struct('<8sII')
FRAME_HEADER = struct.Struct('<4sIQQHHII')
MAX_FRAMES = 32768
MAX_RAW = STREAM_HEADER.size + MAX_FRAMES * (FRAME_HEADER.size + 64000)
MAX_ARCHIVE = 512 * 1024**2
DISK_RESERVE = 2 * 1024**3
BOARD_ROOT = re.compile(r'/dev/shm/ventium-quake-abi5-run\.[A-Za-z0-9]+\Z')


class Validator:
    """Incremental exact-Mode-13 capture validation, with bounded buffering."""
    def __init__(self):
        self.pending = bytearray()
        self.announced = None
        self.count = 0
        self.first = self.last = None

    def feed(self, data):
        if len(data) > 65536:
            raise ValueError('transport chunks must not exceed 64 KiB')
        self.pending.extend(data)
        if self.announced is None and len(self.pending) >= STREAM_HEADER.size:
            magic, version, count = STREAM_HEADER.unpack(self.pending[:STREAM_HEADER.size])
            if (magic, version, count) != (b'VENVCAP1', 1, MAX_FRAMES):
                raise ValueError('wrong capture header or quota')
            self.announced = count
            del self.pending[:STREAM_HEADER.size]
        while self.announced is not None and len(self.pending) >= FRAME_HEADER.size:
            marker, seq, host, cycles, width, height, pixels, crc = FRAME_HEADER.unpack(
                self.pending[:FRAME_HEADER.size])
            if marker != b'VFRM' or (width, height, pixels) != (320, 200, 64000):
                raise ValueError('invalid Mode-13 frame header')
            if seq >= 2**29 or self.count >= self.announced:
                raise ValueError('sequence range or frame quota exceeded')
            if len(self.pending) < FRAME_HEADER.size + pixels:
                break
            payload = self.pending[FRAME_HEADER.size:FRAME_HEADER.size+pixels]
            if zlib.crc32(payload) & 0xffffffff != crc:
                raise ValueError('frame CRC mismatch')
            row = dict(sequence=seq, host_ns=host, cycles=cycles)
            if self.last and not (0 < (seq-self.last['sequence']) % 2**29 < 2**28
                                 and host > self.last['host_ns']
                                 and cycles > self.last['cycles']):
                raise ValueError('frame order, timestamp or cycle counter regressed')
            if self.first is None:
                self.first = row
            self.last = row
            self.count += 1
            del self.pending[:FRAME_HEADER.size+pixels]

    def finish(self):
        # SIGUSR1 stops on a whole-record boundary before the quota. This is
        # transport closure only, NOT proof of full timedemo coverage.
        if self.announced != MAX_FRAMES or not self.count or self.pending:
            raise ValueError('empty or truncated capture stream')


def record(root, argv, *, seconds=4500, idle_seconds=650):
    """Record one process's binary stdout; retain failures as failed evidence."""
    if shutil.disk_usage(root).free < DISK_RESERVE + 1024**3:
        raise ValueError('capture needs 3 GiB starting disk reserve')
    if not 0 < seconds <= 4500 or not 0 < idle_seconds <= 650:
        raise ValueError('invalid bounded transport deadline')
    # Refuse an already used output leaf before launching/opening the reader.
    names = ('raw.vcap.gz', 'transport.stderr', 'transport-start.json',
             'frames.jsonl', 'transport-closed.json')
    if any((root/name).exists() or (root/name).is_symlink() for name in names):
        raise FileExistsError('capture output already exists; never overwrite a run')
    validator = Validator()
    digest = hashlib.sha256()
    total = received = 0
    error = None
    process = None
    rc = None
    started = latest = time.monotonic()
    try:
        with (root/'raw.vcap.gz').open('xb') as stored, (root/'transport.stderr').open('xb') as stderr:
            with gzip.GzipFile(filename='', mode='wb', fileobj=stored, compresslevel=3, mtime=0) as zipped:
                process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=stderr, bufsize=0)
                with (root/'transport-start.json').open('x') as out:
                    json.dump(dict(pid=process.pid, argv=argv, maximum_seconds=seconds,
                                   maximum_idle_seconds=idle_seconds, acceptance=False), out)
                os.set_blocking(process.stdout.fileno(), False)
                with (root/'frames.jsonl').open('x') as progress:
                    while True:
                        now = time.monotonic()
                        if now-started >= seconds or now-latest >= idle_seconds:
                            raise TimeoutError('transport total or idle deadline')
                        if shutil.disk_usage(root).free < DISK_RESERVE or stored.tell() > MAX_ARCHIVE:
                            raise ValueError('capture disk reserve or archive bound')
                        ready, _, _ = select.select([process.stdout], [], [],
                            min(1, seconds-(now-started), idle_seconds-(now-latest)))
                        if not ready:
                            continue
                        block = os.read(process.stdout.fileno(), 65536)
                        if not block:
                            break
                        latest = time.monotonic()
                        received += len(block)
                        if total + len(block) > MAX_RAW:
                            raise ValueError('raw stream bound')
                        digest.update(block)
                        zipped.write(block)
                        total += len(block)
                        before = validator.count
                        validator.feed(block)
                        if validator.count != before:
                            progress.write(json.dumps(dict(frames=validator.count,
                                first=validator.first, last=validator.last))+'\n')
                            progress.flush()
                        if validator.count//16 != before//16:
                            zipped.flush()
                # EOF is not exit success. Cover the wait by the same wall cap.
                remaining = seconds-(time.monotonic()-started)
                if remaining <= 0:
                    raise TimeoutError('transport total deadline before reader exit')
                rc = process.wait(timeout=min(15, remaining))
                if rc != 0:
                    raise RuntimeError(f'reader exited {rc}')
                validator.finish()
        if (root/'raw.vcap.gz').stat().st_size > MAX_ARCHIVE:
            raise ValueError('closed archive exceeds bound')
    except BaseException as exc:
        error = repr(exc)
    finally:
        if process is not None:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            rc = process.returncode
            process.stdout.close()
        result = dict(result='PASS_CLOSED_FRAME_TRANSPORT' if error is None else 'FAILED_TRANSPORT',
            reader_exit=rc, error=error, frames=validator.count, partial_bytes=len(validator.pending),
            raw_bytes=total, received_bytes=received, raw_sha256=digest.hexdigest(),
            first=validator.first, last=validator.last,
            elapsed_seconds=time.monotonic()-started, lossless_storage=error is None, acceptance=False,
            full_timedemo=False, gameplay_ipc=None)
        with (root/'transport-closed.json').open('x') as out:
            json.dump(result, out, indent=2)
            out.write('\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--board-root', required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    if not BOARD_ROOT.fullmatch(args.board_root):
        parser.error('board root must be the fresh ABI-5 tmpfs leaf')
    root = args.output_dir.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    if not root.is_dir() or root == scratch or not root.is_relative_to(scratch) or root.stat().st_uid != os.getuid():
        parser.error('output must be an owned directory beneath external/tmp')
    fifo = args.board_root+'/capture/pixels.fifo'
    argv = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
            '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3',
            'riguke@rk-xczu15eg-f.local', 'exec /bin/cat -- '+fifo]
    result = record(root, argv)
    print(json.dumps(result), flush=True)
    return 0 if result['error'] is None else 1


if __name__ == '__main__':
    raise SystemExit(main())
