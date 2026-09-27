#!/usr/bin/env python3
"""Small host-only test; no generated RTL build or simulation."""
from pathlib import Path
import subprocess
import tempfile

with tempfile.TemporaryDirectory(prefix='ventium-debug-drain-test.') as directory:
    binary = Path(directory) / 'test'
    subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    str(Path(__file__).with_name('test_debug_breakpoint_drain.cpp')),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
