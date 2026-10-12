#!/usr/bin/env python3
"""Execute frozen file-backed PS/2 software tests on ARM, never physical MMIO.

Requires a fresh, owned /dev/shm/ventium-ps2-arm-fixture.* staging directory.
The fixture library cannot open /dev/mem; production is only loaded and queried
for its build marker. This does not qualify device ordering, FPGA or Windows.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import subprocess
import sys
import time


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    root = Path(__file__).resolve().parent
    assert __debug__ and platform.machine() == 'aarch64' and sys.byteorder == 'little'
    assert root.parent == Path('/dev/shm') and root.name.startswith('ventium-ps2-arm-fixture.')
    assert root.stat().st_uid == os.getuid() and root.stat().st_mode & 0o777 == 0o700
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == root
    assert os.sched_getaffinity(0) == {1}
    manifest = json.loads((root/'manifest.json').read_text())
    expected = {'ven_ps2_mmio.c', 'ven_ps2_mmio.py', 'test_ven_ps2_mmio.py',
                'ven_ps2_mouse.py', 'test_ven_ps2_mouse.py', 'ven_ps2_mailbox_host.py',
                'test_ven_ps2_mailbox_host.py', 'ven_ps2_service.py', 'test_ven_ps2_service.py',
                'fixture.so', 'libven_ps2_mmio.so', Path(__file__).name}
    assert set(manifest['files']) == expected
    assert all(not (root/name).is_symlink() and sha(root/name) == digest
               for name, digest in manifest['files'].items())
    assert manifest['physical_mmio_tested'] is False
    libraries = {}
    for name, marker in (('fixture.so', 1), ('libven_ps2_mmio.so', 0)):
        lib = ctypes.CDLL(str(root/name), use_errno=True)
        lib.ven_ps2_mmio_fixture_build.restype = ctypes.c_uint
        assert lib.ven_ps2_mmio_fixture_build() == marker
        assert hasattr(lib, 'ven_ps2_mmio_open_fixture') == bool(marker)
        libraries[name] = lib  # Retain native handles through the test.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_AS, (256 << 20, 256 << 20))
    resource.setrlimit(resource.RLIMIT_FSIZE, (8 << 20, 8 << 20))
    resource.setrlimit(resource.RLIMIT_CPU, (60, 60))
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', VEN_PS2_TEST_ROOT=str(root),
               VEN_PS2_MMIO_TEST_LIB=str(root/'fixture.so'))
    command = [sys.executable, '-B', '-m', 'unittest', '-v', 'test_ven_ps2_mouse',
               'test_ven_ps2_mailbox_host', 'test_ven_ps2_mmio', 'test_ven_ps2_service']
    started = time.monotonic()
    with (root/'unit.log').open('xb') as log:
        child = subprocess.run(command, cwd=root, env=env, stdout=log,
                               stderr=subprocess.STDOUT, timeout=60)
    text = (root/'unit.log').read_text()
    stable = all(sha(root/name) == digest for name, digest in manifest['files'].items())
    result = dict(passed=child.returncode == 0 and stable and 'Ran 61 tests' in text
                  and text.endswith('\nOK\n'), command=command, native_exit=child.returncode,
                  elapsed_seconds=time.monotonic()-started, child_reaped=True,
                  inputs_unchanged=stable, uname=list(platform.uname()), python=sys.version,
                  affinity=sorted(os.sched_getaffinity(0)), page_bytes=os.sysconf('SC_PAGESIZE'),
                  boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                  manifest_sha256=sha(root/'manifest.json'), unit_log_sha256=sha(root/'unit.log'),
                  production_library_loaded=True, production_open_called=False,
                  physical_mmio_tested=False, device_ordering_tested=False,
                  fpga_guest_started=False, windows_mouse_acceptance=False, gameplay_ipc=None)
    with (root/'closed.json').open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
