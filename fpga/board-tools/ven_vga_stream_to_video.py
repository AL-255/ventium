#!/usr/bin/env python3
"""Validate a VENVCAP1 stream and produce timestamped images and/or a video.

The board-side ven_board_probe.py vga-capture --stream command emits the
binary input used here. The stream carries RGB332 frames in scan order plus
the FPGA-cycle timestamp at which each frame was frozen. This tool runs on
the host so that a long Quake capture never needs to fill board storage.
"""

from __future__ import annotations

import argparse
import json
import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path
from typing import BinaryIO


STREAM_MAGIC = b"VENVCAP1"
STREAM_VERSION = 1
STREAM_HEADER = struct.Struct("<8sII")
FRAME_HEADER = struct.Struct("<4sIQQHHII")


def _riff_chunk(fourcc: bytes, payload: bytes) -> bytes:
    """Return one word-aligned RIFF chunk."""
    if len(fourcc) != 4:
        raise ValueError("RIFF fourcc must be four bytes")
    return fourcc + struct.pack("<I", len(payload)) + payload + (b"\0" if len(payload) & 1 else b"")


def _riff_list(list_type: bytes, payload: bytes) -> bytes:
    """Return one word-aligned RIFF LIST chunk."""
    if len(list_type) != 4:
        raise ValueError("RIFF list type must be four bytes")
    return _riff_chunk(b"LIST", list_type + payload)


class RawAviWriter:
    """Small dependency-free AVI writer for top-down uncompressed BGR24.

    The intended 320x200 x 969-frame capture is only about 186 MiB, safely
    below AVI 1.0's 4-GiB RIFF limit.  Keeping this writer here makes a
    validated capture usable even on a lean host without ffmpeg.
    """

    def __init__(self, path: Path, width: int, height: int, fps: float, frames: int):
        if frames < 1:
            raise ValueError("AVI needs at least one frame")
        self.width = width
        self.height = height
        self.frame_count = frames
        self.row_bytes = (width * 3 + 3) & ~3
        self.frame_bytes = self.row_bytes * height
        self.written = 0
        # AVI rate/scale is rational; millihertz retains familiar rates such
        # as 29.97 exactly enough for this diagnostic recording.
        self.rate = max(1, round(fps * 1000))
        self.scale = 1000
        self.target = path.open("w+b")
        self.index: list[tuple[int, int]] = []

        microseconds = round(1_000_000 * self.scale / self.rate)
        avih = struct.pack(
            "<IIIIIIIIII4I",
            microseconds,
            round(self.frame_bytes * fps),
            0,
            0x10,  # AVIF_HASINDEX
            frames,
            0,
            1,
            self.frame_bytes,
            width,
            height,
            0,
            0,
            0,
            0,
        )
        strh = struct.pack(
            "<4s4sIHHIIIIIIIIhhhh",
            b"vids",
            b"DIB ",
            0,
            0,
            0,
            0,
            self.scale,
            self.rate,
            0,
            frames,
            self.frame_bytes,
            0xFFFF_FFFF,
            0,
            0,
            0,
            width,
            height,
        )
        # Negative height declares a top-down DIB, matching VGA scan order.
        strf = struct.pack(
            "<IiiHHIIiiII",
            40,
            width,
            -height,
            1,
            24,
            0,
            self.frame_bytes,
            0,
            0,
            0,
            0,
        )
        hdrl = _riff_chunk(b"avih", avih) + _riff_list(
            b"strl", _riff_chunk(b"strh", strh) + _riff_chunk(b"strf", strf)
        )
        self.target.write(b"RIFF\0\0\0\0AVI ")
        self.target.write(_riff_list(b"hdrl", hdrl))
        self.movi_list = self.target.tell()
        self.target.write(b"LIST\0\0\0\0movi")
        self.movi_size_offset = self.movi_list + 4
        self.movi_type_offset = self.movi_list + 8

    def write_rgb24(self, rgb24: bytes) -> None:
        if len(rgb24) != self.width * self.height * 3:
            raise ValueError("AVI frame has unexpected RGB24 length")
        if self.written >= self.frame_count:
            raise ValueError("AVI received more frames than announced")

        bgr = bytearray(self.frame_bytes)
        source = 0
        target = 0
        for _ in range(self.height):
            row_end = source + self.width * 3
            while source < row_end:
                bgr[target] = rgb24[source + 2]
                bgr[target + 1] = rgb24[source + 1]
                bgr[target + 2] = rgb24[source]
                source += 3
                target += 3
            target += self.row_bytes - self.width * 3

        chunk_start = self.target.tell()
        self.target.write(_riff_chunk(b"00db", bytes(bgr)))
        self.index.append((chunk_start - self.movi_type_offset, self.frame_bytes))
        self.written += 1

    def close(self) -> None:
        if self.target.closed:
            return
        try:
            if self.written != self.frame_count:
                raise RuntimeError(
                    f"AVI received {self.written} frame(s), expected {self.frame_count}"
                )
            movi_end = self.target.tell()
            self.target.seek(self.movi_size_offset)
            self.target.write(struct.pack("<I", movi_end - (self.movi_size_offset + 4)))
            self.target.seek(movi_end)
            index = b"".join(
                struct.pack("<4sIII", b"00db", 0x10, offset, size)
                for offset, size in self.index
            )
            self.target.write(_riff_chunk(b"idx1", index))
            final_size = self.target.tell()
            self.target.seek(4)
            self.target.write(struct.pack("<I", final_size - 8))
        finally:
            self.target.close()

    def abort(self) -> None:
        """Close an incomplete AVI without hiding the parsing failure."""
        if not self.target.closed:
            self.target.close()


def read_exact(source: BinaryIO, count: int) -> bytes:
    data = source.read(count)
    if len(data) != count:
        raise RuntimeError(f"truncated capture stream: wanted {count} bytes, got {len(data)}")
    return data


def rgb332_to_rgb24(pixels: bytes) -> bytes:
    output = bytearray(len(pixels) * 3)
    for index, value in enumerate(pixels):
        red3 = (value >> 5) & 0x7
        green3 = (value >> 2) & 0x7
        blue2 = value & 0x3
        offset = index * 3
        output[offset] = (red3 << 5) | (red3 << 2) | (red3 >> 1)
        output[offset + 1] = (green3 << 5) | (green3 << 2) | (green3 >> 1)
        output[offset + 2] = (blue2 << 6) | (blue2 << 4) | (blue2 << 2) | blue2
    return bytes(output)


def write_ppm(path: Path, width: int, height: int, rgb24: bytes) -> None:
    with path.open("wb") as target:
        target.write(f"P6\n{width} {height}\n255\n".encode("ascii"))
        target.write(rgb24)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="VENVCAP1 stream captured over SSH")
    parser.add_argument("--manifest", type=Path, required=True, help="write validated frame metadata JSON here")
    parser.add_argument("--ppm-dir", type=Path, help="optionally write one PPM per frame")
    parser.add_argument(
        "--video",
        type=Path,
        help="optionally encode a constant-rate video (.avi uses the built-in uncompressed writer; other suffixes use ffmpeg)",
    )
    parser.add_argument("--fps", type=float, default=30.0, help="constant video rate for --video (default: 30)")
    parser.add_argument(
        "--clock-hz",
        type=float,
        default=3_125_000.0,
        help="PL clock used to convert FPGA-cycle timestamps in the manifest (default: 3125000)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.fps <= 0:
        raise SystemExit("--fps must be positive")
    if args.clock_hz <= 0:
        raise SystemExit("--clock-hz must be positive")
    raw_avi = bool(args.video and args.video.suffix.lower() == ".avi")
    if args.video and not raw_avi and shutil.which("ffmpeg") is None:
        raise SystemExit("ffmpeg is required for non-AVI --video output but is not on PATH")

    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    if args.ppm_dir:
        args.ppm_dir.mkdir(parents=True, exist_ok=True)
    if args.video:
        args.video.parent.mkdir(parents=True, exist_ok=True)

    manifest_frames: list[dict[str, int | float | str]] = []
    encoder: subprocess.Popen[bytes] | None = None
    avi: RawAviWriter | None = None
    dimensions: tuple[int, int] | None = None
    try:
        with args.input.open("rb") as source:
            magic, version, announced_count = STREAM_HEADER.unpack(read_exact(source, STREAM_HEADER.size))
            if magic != STREAM_MAGIC or version != STREAM_VERSION:
                raise RuntimeError(
                    f"unsupported stream header magic={magic!r} version={version}; "
                    f"expected {STREAM_MAGIC!r} v{STREAM_VERSION}"
                )

            for index in range(announced_count):
                marker, sequence, host_ns, cycle, width, height, pixels, checksum = FRAME_HEADER.unpack(
                    read_exact(source, FRAME_HEADER.size)
                )
                if marker != b"VFRM":
                    raise RuntimeError(f"frame {index}: bad marker {marker!r}")
                if not width or not height or pixels != width * height:
                    raise RuntimeError(f"frame {index}: invalid dimensions {width}x{height}, pixels={pixels}")
                if dimensions is None:
                    dimensions = width, height
                    if args.video and raw_avi:
                        avi = RawAviWriter(args.video, width, height, args.fps, announced_count)
                    elif args.video:
                        encoder = subprocess.Popen(
                            [
                                "ffmpeg", "-y", "-loglevel", "warning",
                                "-f", "rawvideo", "-pixel_format", "rgb24",
                                "-video_size", f"{width}x{height}", "-framerate", str(args.fps),
                                "-i", "-", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(args.video),
                            ],
                            stdin=subprocess.PIPE,
                        )
                        assert encoder.stdin is not None
                elif dimensions != (width, height):
                    raise RuntimeError(
                        f"frame {index}: dimension changed from {dimensions[0]}x{dimensions[1]} "
                        f"to {width}x{height}; cannot encode one video"
                    )

                payload = read_exact(source, pixels)
                observed_crc = zlib.crc32(payload) & 0xFFFF_FFFF
                if observed_crc != checksum:
                    raise RuntimeError(
                        f"frame {index}: CRC mismatch got={observed_crc:08x} expected={checksum:08x}"
                    )
                rgb24 = rgb332_to_rgb24(payload)
                if args.ppm_dir:
                    write_ppm(args.ppm_dir / f"frame-{index:06d}.ppm", width, height, rgb24)
                if avi:
                    avi.write_rgb24(rgb24)
                if encoder:
                    assert encoder.stdin is not None
                    encoder.stdin.write(rgb24)
                manifest_frames.append(
                    {
                        "index": index,
                        "sequence": sequence,
                        "fpga_cycle": cycle,
                        "fpga_seconds": cycle / args.clock_hz,
                        "host_read_completed_ns": host_ns,
                        "width": width,
                        "height": height,
                        "pixels": pixels,
                        "crc32": f"{checksum:08x}",
                    }
                )
            if source.read(1):
                raise RuntimeError("capture stream has trailing data")

        if encoder:
            assert encoder.stdin is not None
            encoder.stdin.close()
            if encoder.wait() != 0:
                raise RuntimeError("ffmpeg failed while encoding the capture")
        if avi:
            avi.close()

        args.manifest.write_text(
            json.dumps(
                {
                    "format": "VENVCAP1/RGB332",
                    "stream_version": STREAM_VERSION,
                    "announced_frames": announced_count,
                    "clock_hz": args.clock_hz,
                    "video_fps": args.fps if args.video else None,
                    "frames": manifest_frames,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        print(f"validated {len(manifest_frames)} VGA frame(s)")
        return 0
    finally:
        if avi:
            avi.abort()
        if encoder and encoder.poll() is None:
            encoder.kill()
            encoder.wait()


if __name__ == "__main__":
    raise SystemExit(main())
