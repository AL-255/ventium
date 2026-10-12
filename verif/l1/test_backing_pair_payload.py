"""Exercise extracted original/candidate backing drive, including idle credit hints."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

import prepare_backing_pair_payload as recipe


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fixture(source, mode):
    body = ''
    for prefix in ('old_', 'new_'):
        for name, width in recipe.FIELDS.items():
            body += f'  logic [{width-1}:0] {prefix}{name};\n'
    body += recipe.rename(recipe.block(source), 'old_')
    new = recipe.changed_block(source)
    mutations = {
        'wrong-v': ("if (!c_we) begin m_addr=c_pair_addr; m_wstrb=c_pair_wstrb; end",
                    "if (!c_we) begin m_addr=c_addr; m_wstrb=c_wstrb; end"),
        'fill-strobe': ("      m_wstrb = 4'd0; // retain the complete original fill packet\n", ''),
        'lost-credit': ('m_req=c_pair_req && c_pair_ready;', 'm_req=c_pair_req;'),
        'late-hint': ('    m_addr=c_addr; m_wstrb=c_wstrb;',
                      "    m_addr=c_req ? c_addr : 32'd0; m_wstrb=c_wstrb;"),
    }
    if mode != 'positive':
        before, after = mutations[mode]
        assert new.count(before) == 1
        new = new.replace(before, after)
    body += recipe.rename(new, 'new_')
    template = Path(__file__).with_name('tb_backing_pair_payload.sv').read_text()
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
            Path(recipe.__file__).resolve(), Path(__file__).with_name('tb_backing_pair_payload.sv'))}
    source = source_path.read_text()
    derivative = recipe.transform(source)
    assert derivative == source.replace(recipe.block(source),
                         recipe.changed_block(source) + recipe.witness(source))
    for bad in (source + '\n', derivative):
        try:
            recipe.transform(bad)
        except ValueError:
            pass
        else:
            raise AssertionError('source drift/reapplication accepted')
    profiles = dict(default=[], dual=['VEN_P54_DUAL_STORE_PAIR'],
                    full=['VEN_P54_DUAL_STORE_PAIR', 'VEN_P54_LOAD_STORE_PAIR'])
    root.mkdir()
    (root / 'ven_l1d.sv').write_text(derivative)
    rows = []
    started = time.monotonic()
    for profile, defines in profiles.items():
        modes = ('positive', 'wrong-v', 'fill-strobe', 'lost-credit', 'late-hint') if profile == 'full' else ('positive',)
        for mode in modes:
            case = root / (profile + '-' + mode)
            case.mkdir()
            sv = case / 'tb.sv'
            sv.write_text(fixture(source, mode))
            binary = case / 'test.vvp'
            command = ['/usr/bin/iverilog', '-g2012', '-s', 'tb', '-o', str(binary),
                       *['-D' + flag for flag in defines], str(sv)]
            built = subprocess.run(command, text=True, capture_output=True, timeout=15)
            (case / 'build.log').write_text(built.stdout + built.stderr)
            assert built.returncode == 0, (profile, mode, built.stderr)
            run = subprocess.run(['/usr/bin/vvp', str(binary)], text=True,
                                 capture_output=True, timeout=60)
            log = run.stdout + run.stderr
            (case / 'run.log').write_text(log)
            expected = 0 if mode == 'positive' else 1
            marker = ('BACKING-PAYLOAD-OK checks=524288' if mode == 'positive'
                      else 'BACKING-PAYLOAD-MISMATCH')
            assert run.returncode == expected and marker in log, (profile, mode, run.returncode, log)
            row = dict(profile=profile, mode=mode, native_exit=run.returncode, output=log,
                       command=command, sv_sha256=sha(sv), binary_sha256=sha(binary))
            rows.append(row)
            print(json.dumps({k: v for k, v in row.items() if k != 'command'}), flush=True)
    assert all(sha(p) == h for p, h in pins.items())
    result = dict(passed=True, pins=pins, pins_unchanged=True, rows=rows,
                  derivative_sha256=sha(root / 'ven_l1d.sv'), seconds=time.monotonic()-started,
                  native_4state_simulator=True, stimulus_binary=True,
                  sequential_cache=False, real_axi_master=False, whole_core=False,
                  gameplay_ipc=None, fmax_mhz=None)
    (root / 'closed.json').write_text(json.dumps(result, indent=2) + '\n')
    print('BACKING-PAYLOAD-LEAF-CLOSED', root / 'closed.json', flush=True)


if __name__ == '__main__':
    main()
