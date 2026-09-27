#!/usr/bin/env python3
"""Verify/stage the fixed same-build gameplay checkpoint bundle; never launch it."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import stat
import subprocess

FILES = frozenset(("ao486sim_ven", "rom/boot0.rom", "rom/boot1.rom",
                   "gameplay.snap", "guest.vhd"))
RECEIPT = "gameplay.sha256"


def regular_file(root, name):
    path = root
    for part in Path(name).parts:
        path = path / part
        if path.is_symlink():
            raise ValueError(f"symlink forbidden in bundle: {name}")
    if not path.is_file():
        raise ValueError(f"missing regular bundle file: {name}")
    return path


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def verify_bundle(directory):
    root = Path(directory).resolve(strict=True)
    entries = {}
    receipt = regular_file(root, RECEIPT)
    if receipt.stat().st_size > 4096:
        raise ValueError("oversized bundle receipt")
    for line in receipt.read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            raise ValueError("invalid SHA-256 receipt line")
        sha, name = match.groups()
        if name not in FILES or name in entries:
            raise ValueError(f"unexpected/duplicate bundle path: {name}")
        entries[name] = sha
    if set(entries) != FILES:
        raise ValueError("incomplete bundle receipt")
    for name, expected in entries.items():
        if digest(regular_file(root, name)) != expected:
            raise ValueError(f"bundle hash mismatch: {name}")
    return root


def stage_bundle(directory, destination):
    root = verify_bundle(directory)
    out = Path(destination)
    # A prior run's writable disk must never be overwritten or mistaken for a
    # fresh copy. A failed staging operation leaves its new directory for audit.
    out.mkdir()
    (out / "rom").mkdir()
    for name in sorted(FILES | {RECEIPT}):
        source = regular_file(root, name)
        target = out / name
        if name == "guest.vhd":
            # Match the Linux cold-capture flow: preserve sparse disk holes,
            # with an independent copy (or copy-on-write reflink), never a
            # hard link. copy2 alone allocates the entire virtual disk size.
            # Do not fall back to a dense copy on failure; leave this fresh
            # output directory available for inspection, as for other errors.
            subprocess.run(["cp", "--reflink=auto", "--sparse=always", "--",
                            str(source), str(target)], check=True)
            shutil.copystat(source, target)
        else:
            shutil.copy2(source, target)
    # Recheck the actual copies, catching input changes during staging as well
    # as copy errors. Caller executes only this copy, never the source bundle.
    verify_bundle(out)
    # Copying preserves archived read-only modes. The emulator writes only its
    # private disk; retain all other modes and leave the source bundle intact.
    disk = out / "guest.vhd"
    disk.chmod(stat.S_IMODE(disk.stat().st_mode) | stat.S_IWUSR)
    return out.resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--stage", type=Path, help="new private replay directory (must not exist)")
    args = parser.parse_args()
    try:
        out = stage_bundle(args.bundle, args.stage) if args.stage else verify_bundle(args.bundle)
    except (OSError, ValueError, UnicodeError, subprocess.CalledProcessError) as exc:
        parser.exit(2, f"CHECKPOINT-BUNDLE-FAIL: {exc}\n")
    print(f"CHECKPOINT-BUNDLE-OK: {out}")
    if args.stage:
        print("Private replay copies ready; no simulator started. Native snapshots are same-build only.")


if __name__ == "__main__":
    main()
