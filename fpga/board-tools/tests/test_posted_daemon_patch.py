#!/usr/bin/env python3
"""Exact-context application/refusal checks; no daemon execution or board I/O."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    original = Path(sys.argv[1]).resolve(strict=True)
    scratch = Path(sys.argv[2]).resolve(strict=True)
    repo = Path(__file__).resolve().parents[3]
    source = original.read_bytes()
    assert hashlib.sha256(source).hexdigest() == '1b9486c52438dc255903420b9ed0b05961c4f74f869204f84809081d2505f3c9'
    patch = repo/'fpga/patches/ao486d-posted-reset-drain.patch'
    with tempfile.TemporaryDirectory(prefix='posted-daemon-patch.', dir=scratch) as work:
        root = Path(work); (root/'src').mkdir()
        target = root/'src/board_shim.cpp'; target.write_bytes(source)
        command = ['patch','--batch','--forward','--fuzz=0','-p1','-i',str(patch)]
        result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=5)
        assert result.returncode == 0 and 'offset' not in result.stdout and 'fuzz' not in result.stdout, result
        body = target.read_text()
        assert hashlib.sha256(target.read_bytes()).hexdigest() == '73208f9072a23d08b8e80fb92e3473a7f78fa31939f0b43c915784a977fd9f24'
        assert body.index('wait_for_reset_drain(', body.index('int main(')) < body.index('ddr_fill_scalar(ddr, 0, DDR_SIZE)')
        assert subprocess.run(command+['--dry-run'],cwd=root,capture_output=True,timeout=5).returncode != 0
        # A changed reset call must not be papered over with patch fuzz.
        assert source.count(b'    core_hold_reset();\n    dump_dbg("held");') == 1
        target.write_bytes(source.replace(b'    core_hold_reset();\n    dump_dbg("held");',
                                         b'    core_release();\n    dump_dbg("held");'))
        result = subprocess.run(command+['--dry-run'],cwd=root,capture_output=True,text=True,timeout=5)
        assert result.returncode != 0 and 'FAILED' in result.stdout
    assert original.read_bytes() == source
    print('POSTED-DAEMON-PATCH-OK: exact source/output, ordering, duplicate and changed-reset refusal')


if __name__ == '__main__':
    main()
