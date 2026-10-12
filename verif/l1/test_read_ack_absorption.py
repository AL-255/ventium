"""Source-extracted binary read-ACK comparison and native mutation controls."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

import prepare_read_ack_absorption as recipe


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fixture(source, mode):
    body = ''
    for name in ('code_access', 'code_hit', 'rd_match', 'mc_lookup_old',
                 'mc_lookup_prime', 'mc_lookup_next', 'window_reuse',
                 'shadow_reuse', 'code_word_reuse'):
        body += recipe.assignment(source, name)
    old = recipe.ack_block(source)
    body += old.replace('c_read_ack', 'old_ack')
    transformed = recipe.transform(source)
    new = recipe.helpers(source) + recipe.ack_block(transformed)
    if mode == 'lost-owner':
        before = '(rd_match && !flush_all && !snoop_inv_valid'
        assert new.count(before) == 1
        new = new.replace(before, "(1'b0 && !flush_all && !snoop_inv_valid")
    elif mode == 'lost-residency':
        assert new.count('assign read_ack_current_hit = |tag_current_hit;') == 1
        new = new.replace('assign read_ack_current_hit = |tag_current_hit;',
                          "assign read_ack_current_hit = 1'b1;")
    elif mode == 'lost-cache':
        before = '&& !(BYPASS_RD_EN && !cacheable)'
        assert new.count(before) == 2
        new = new.replace(before, '')
    elif mode == 'lost-flush':
        new = new.replace('!flush_all', "1'b1")
    body += new.replace('c_read_ack', 'new_ack')
    template = Path(__file__).with_name('tb_read_ack_absorption.sv').read_text()
    assert template.count('  // EXTRACTED_EQUATIONS') == 1
    return template.replace('  // EXTRACTED_EQUATIONS', body)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    source_path = args.source.resolve(strict=True)
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != Path(__file__).stat().st_dev
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert sha(source_path) == recipe.PARENT
    pins = {str(p): sha(p) for p in (source_path, Path(__file__).resolve(),
            Path(recipe.__file__).resolve(), Path(__file__).with_name('tb_read_ack_absorption.sv'))}
    source = source_path.read_text()
    derivative = recipe.transform(source)
    assert derivative == source.replace(recipe.ack_block(source),
                                       recipe.helpers(source) + recipe.ack_block(derivative))
    for bad in (source + '\n', derivative):
        try:
            recipe.transform(bad)
        except ValueError:
            pass
        else:
            raise AssertionError('source drift/reapplication accepted')
    defines = ['VEN_FP_LOAD_EARLY_CMD', 'VEN_PIPE_MEM_CHAIN', 'VEN_PIPE_REG_LOAD_PRIME',
               'VEN_L1D_PRIME_UNDER_FILL', 'VEN_L1D_CODE_BUFFER', 'VEN_L1D_WINDOW_REUSE',
               'VEN_L1D_TWO_WINDOW_REUSE', 'VEN_L1D_CODE_WORD_REUSE', 'VEN_L1D_HIT_STREAM']
    root.mkdir()
    (root / 'ven_l1d.sv').write_text(derivative)
    rows = []
    for mode in ('positive', 'lost-owner', 'lost-residency', 'lost-cache', 'lost-flush'):
        case = root / mode
        case.mkdir()
        sv = case / 'tb.sv'
        sv.write_text(fixture(source, mode))
        binary = case / 'test.vvp'
        command = ['/usr/bin/iverilog', '-g2012', '-s', 'tb', '-o', str(binary),
                   *['-D' + flag for flag in defines], str(sv)]
        built = subprocess.run(command, text=True, capture_output=True, timeout=15)
        (case / 'build.log').write_text(built.stdout + built.stderr)
        assert built.returncode == 0, (mode, built.stderr)
        run = subprocess.run(['/usr/bin/vvp', str(binary)], text=True,
                             capture_output=True, timeout=40)
        log = run.stdout + run.stderr
        (case / 'run.log').write_text(log)
        expected = 0 if mode == 'positive' else 1
        marker = ('READ-ACK-ABSORPTION-OK checks=216384' if mode == 'positive'
                  else 'READ-ACK-ABSORPTION-MISMATCH')
        assert run.returncode == expected and marker in log, (mode, run.returncode, log)
        rows.append(dict(mode=mode, native_exit=run.returncode, output=log,
                         sv_sha256=sha(sv), binary_sha256=sha(binary)))
    assert all(sha(p) == h for p, h in pins.items())
    result = dict(passed=True, pins=pins, pins_unchanged=True, rows=rows,
                  derivative_sha256=sha(root / 'ven_l1d.sv'), native_4state_simulator=True,
                  stimulus_binary=True, sequential_cache=False, whole_core=False,
                  gameplay_ipc=None, fmax_mhz=None)
    (root / 'closed.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'pins'}), flush=True)


if __name__ == '__main__':
    main()
