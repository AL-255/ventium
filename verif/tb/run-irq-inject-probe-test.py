#!/usr/bin/env python3
"""Lightweight host-only compile and positive/negative IRQ-hook tests."""
from pathlib import Path
import resource
import subprocess
import tempfile

root = Path(__file__).resolve().parent
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
with tempfile.TemporaryDirectory(prefix='ventium-irq-host-test.') as directory:
    binary = Path(directory) / 'test'
    subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    str(root / 'test_irq_inject_probe.cpp'), '-o', str(binary)], check=True)
    cases = {'ok': None, 'nosoc': 'requires SOC', 'noasync': 'requires SOC',
             'unsolicited': 'unsolicited', 'duplicate': 'unsolicited',
             'owners': 'before FP owner drain', 'vector': 'wrong-vector',
             'timeout': 'not acknowledged', 'missing': 'missing/duplicate'}
    for case, error in cases.items():
        result = subprocess.run([str(binary), case], capture_output=True, text=True)
        assert (result.returncode == 0) == (error is None), (case, result)
        assert error is None or error in result.stderr, (case, result)
        print(f'{case}: PASS')
print('IRQ-INJECT-HOST-GATE-OK')
