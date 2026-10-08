#!/usr/bin/env python3
"""Stream a closed RGB332 recording to lossless 15 fps RGB video.

This verifies the movie against every captured byte. It does not establish
producer success, complete timedemo coverage, source clock, or CPU correctness.
An intact recording of a failed guest remains a failed-guest recording.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import resource
import select
import shutil
import stat
import subprocess
import time

import ven_record_stream as transport

FPS = 15
FRAME_BYTES = 320 * 200
MAX_MOVIE = 512 * 1024**2
MAX_AS = 512 * 1024**2
RGB_TABLE = tuple(bytes(((r << 5) | (r << 2) | (r >> 1),
                         (g << 5) | (g << 2) | (g >> 1), b * 85))
                  for r in range(8) for g in range(8) for b in range(4))


def identity(path):
    value = path.stat()
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def require_file(path, maximum):
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode) or value.st_uid != os.getuid() or value.st_size > maximum:
        raise ValueError('expected bounded, owned regular input: ' + str(path))


def frames(capture, receipt):
    """Validate one gzip stream incrementally; never load the recording into RAM."""
    if not (receipt.get('result') == 'PASS_CLOSED_FRAME_TRANSPORT'
            and receipt.get('reader_exit') == 0 and receipt.get('error') is None
            and receipt.get('lossless_storage') is True and receipt.get('partial_bytes') == 0
            and type(receipt.get('frames')) is int and 0 < receipt['frames'] <= transport.MAX_FRAMES
            and type(receipt.get('raw_bytes')) is int and 0 < receipt['raw_bytes'] <= transport.MAX_RAW
            and receipt.get('received_bytes') == receipt['raw_bytes']):
        raise ValueError('transport is not a successfully closed recording')
    path = capture/'raw.vcap.gz'
    require_file(path, transport.MAX_ARCHIVE)
    before = identity(path)
    validator = transport.Validator()
    digest = hashlib.sha256()
    size = 0
    with path.open('rb') as raw, gzip.GzipFile(fileobj=raw, mode='rb') as source:
        def read_exact(count):
            nonlocal size
            data = source.read(count)
            if len(data) != count:
                raise ValueError('truncated recording')
            size += count
            if size > transport.MAX_RAW:
                raise ValueError('recording exceeds raw bound')
            digest.update(data)
            return data
        validator.feed(read_exact(transport.STREAM_HEADER.size))
        for _ in range(receipt['frames']):
            # Validate fixed geometry before accepting a variable-length read.
            header = read_exact(transport.FRAME_HEADER.size)
            validator.feed(header)
            pixels = read_exact(FRAME_BYTES)
            validator.feed(pixels)
            yield pixels
        if source.read(1):
            raise ValueError('extra recording data')
        validator.finish()
    if identity(path) != before:
        raise ValueError('recording changed while read')
    if (size != receipt['raw_bytes'] or digest.hexdigest() != receipt['raw_sha256']
            or validator.count != receipt['frames'] or validator.first != receipt['first']
            or validator.last != receipt['last']):
        raise ValueError('recording differs from transport receipt')


def remaining(deadline):
    value = deadline-time.monotonic()
    if value <= 0:
        raise TimeoutError('codec whole-stage deadline')
    return value


def limits():
    resource.setrlimit(resource.RLIMIT_AS, (MAX_AS, MAX_AS))
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_MOVIE, MAX_MOVIE))


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    for stream in (process.stdin, process.stdout):
        if stream is not None:
            stream.close()


def write_frame(process, data, deadline, output):
    fd = process.stdin.fileno()
    os.set_blocking(fd, False)
    view = memoryview(data)
    while view:
        if process.poll() is not None:
            raise RuntimeError('encoder exited before consuming recording')
        if shutil.disk_usage(output).free < transport.DISK_RESERVE:
            raise ValueError('movie disk reserve')
        _, ready, _ = select.select([], [fd], [], min(1, remaining(deadline)))
        if ready:
            try:
                count = os.write(fd, view)
            except BlockingIOError:
                continue
            if count <= 0:
                raise RuntimeError('encoder pipe made no progress')
            view = view[count:]


def decode_hash(process, expected, deadline):
    fd = process.stdout.fileno()
    os.set_blocking(fd, False)
    digest = hashlib.sha256()
    count = 0
    while True:
        ready, _, _ = select.select([fd], [], [], min(1, remaining(deadline)))
        if not ready:
            continue
        try:
            block = os.read(fd, 65536)
        except BlockingIOError:
            continue
        if not block:
            break
        count += len(block)
        if count > expected:
            raise ValueError('decoder produced extra RGB data')
        digest.update(block)
    if process.wait(timeout=remaining(deadline)) != 0 or count != expected:
        raise ValueError('decoder failed or RGB length differs')
    return digest.hexdigest()


def check_movie_probe(data, count):
    streams = data.get('streams', [])
    if len(streams) != 1:
        raise ValueError('expected one movie video stream')
    stream = streams[0]
    if (stream.get('width') != 320 or stream.get('height') != 200
            or stream.get('r_frame_rate') != '15/1' or stream.get('avg_frame_rate') != '15/1'
            or stream.get('nb_frames') != str(count)
            or abs(float(stream.get('duration', 'nan')) - count/FPS) > 0.001
            or not float(stream.get('duration', 'nan')) > 0):
        raise ValueError('movie dimensions, frame count or presentation cadence differ')


def encode(capture, output, *, seconds=600):
    if not 0 < seconds <= 1800:
        raise ValueError('codec deadline must be at most 1800 seconds per stage')
    if shutil.disk_usage(output).free < transport.DISK_RESERVE+MAX_MOVIE:
        raise ValueError('movie requires 2.5 GiB starting disk reserve')
    for name in ('recording-15fps.mp4', 'movie.json', 'encoder.stderr', 'decoder.stderr'):
        path = output/name
        if path.exists() or path.is_symlink():
            raise FileExistsError('never overwrite a prior movie attempt')
    ffmpeg = Path(shutil.which('ffmpeg') or '/__missing_ffmpeg__').resolve(strict=True)
    ffprobe = Path(shutil.which('ffprobe') or '/__missing_ffprobe__').resolve(strict=True)
    receipt_path = capture/'transport-closed.json'
    require_file(receipt_path, 65536)
    receipt_sha = sha(receipt_path)
    receipt = json.loads(receipt_path.read_text())
    movie = output/'recording-15fps.mp4'
    result = dict(result='FAILED_MOVIE', full_timedemo=False, acceptance=False, gameplay_ipc=None,
                  source_capture=str(capture), transport_receipt_sha256=receipt_sha,
                  dimensions=[320,200], presentation_fps=FPS, no_color_adjustment=True,
                  frame_drop_or_duplication=None, ffmpeg_sha256=sha(ffmpeg),
                  codec_threads=2, codec_stage_seconds=seconds, codec_address_space_bytes=MAX_AS)
    env = dict(os.environ, MALLOC_ARENA_MAX='2')
    base = [str(ffmpeg), '-nostdin', '-hide_banner', '-loglevel', 'error',
            '-threads', '2', '-filter_threads', '1', '-filter_complex_threads', '1']
    command = base+['-n', '-f', 'rawvideo', '-pixel_format', 'rgb24', '-video_size', '320x200',
        '-framerate', str(FPS), '-i', 'pipe:0', '-an', '-c:v', 'libx264rgb', '-crf', '0',
        '-preset', 'veryfast', '-threads', '2', '-movflags', '+faststart', str(movie)]
    result['encoder_argv'] = command
    try:
        digest = hashlib.sha256()
        count = 0
        with (output/'encoder.stderr').open('xb') as errors:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stderr=errors, env=env, preexec_fn=limits)
            try:
                deadline = time.monotonic()+seconds
                for pixels in frames(capture, receipt):
                    rgb = b''.join(RGB_TABLE[value] for value in pixels)
                    digest.update(rgb)
                    count += 1
                    write_frame(process, rgb, deadline, output)
                process.stdin.close()
                result['encoder_exit'] = process.wait(timeout=remaining(deadline))
                if result['encoder_exit'] != 0:
                    raise RuntimeError('encoder native failure')
            finally:
                stop(process)
        if not 0 < movie.stat().st_size <= MAX_MOVIE:
            raise ValueError('encoded movie size bound')
        command = base+['-i', str(movie), '-map', '0:v:0', '-an', '-threads', '2',
                        '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1']
        result['decoder_argv'] = command
        with (output/'decoder.stderr').open('xb') as errors:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors, env=env, preexec_fn=limits)
            try:
                decoded = decode_hash(process, count*FRAME_BYTES*3, time.monotonic()+seconds)
                result['decoder_exit'] = process.returncode
            finally:
                stop(process)
        if decoded != digest.hexdigest() or sha(receipt_path) != receipt_sha:
            raise ValueError('RGB round trip mismatch or changed transport receipt')
        command = [str(ffprobe), '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                   'stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,duration',
                   '-of', 'json', str(movie)]
        probe = subprocess.run(command, env=env, preexec_fn=limits, capture_output=True,
                               timeout=min(30, seconds), check=True)
        if len(probe.stdout) > 8192 or len(probe.stderr) > 8192:
            raise ValueError('unexpected metadata output size')
        metadata = json.loads(probe.stdout)
        check_movie_probe(metadata, count)
        result.update(result='PASS_LOSSLESS_RECORDED_FRAMES_ONLY', frames=count, frame_drop_or_duplication=False,
                      rgb24_sha256=digest.hexdigest(), decoded_rgb24_sha256=decoded,
                      raw_sha256=receipt['raw_sha256'], movie_sha256=sha(movie), movie_bytes=movie.stat().st_size,
                      ffprobe_sha256=sha(ffprobe), movie_metadata=metadata)
    except BaseException as error:
        result['error'] = repr(error)
    with (output/'movie.json').open('x') as target:
        json.dump(result, target, indent=2)
        target.write('\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    for path in (args.capture_dir, args.output_dir):
        resolved = path.resolve(strict=True)
        if (resolved == scratch or not resolved.is_relative_to(scratch)
                or not resolved.is_dir() or resolved.stat().st_uid != os.getuid()):
            parser.error('both directories must be owned leaves beneath external/tmp')
    result = encode(args.capture_dir.resolve(), args.output_dir.resolve())
    print(json.dumps(result))
    return 0 if result['result'] == 'PASS_LOSSLESS_RECORDED_FRAMES_ONLY' else 1


if __name__ == '__main__':
    raise SystemExit(main())
