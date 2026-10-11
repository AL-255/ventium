#!/usr/bin/env python3
"""Native old/new core operand-block and real-decoder regression, plus mutants."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback
from prepare_u_shift_registers import transform, extract

REPO = Path(__file__).resolve().parents[2]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    parent, out = args.parent.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert shutil.disk_usage(scratch).free > 4*1024**3
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    started = json.loads((parent/'build-started.json').read_text())
    built = json.loads((parent/'build-closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    pins = started['pins'].copy()
    assert all(sha(p) == h for p,h in pins.items())
    defs = re.findall(r'\+define\+(\w+)', next(s for s in started['command'] if s.startswith('VL_EXTRA_DEFINES=')))
    assert len(set(defs)) == len(defs) == 150 and 'SYNTHESIS' not in defs
    rtl = parent/'candidate/rtl'
    source = (rtl/'core/core.sv').read_text()
    candidate = transform(source)
    out.mkdir()
    (out/'core.sv').write_text(candidate)
    (out/'original_u.sv').write_text(extract(source, 'original_u'))
    good = extract(candidate, 'candidate_u')
    # Corrupt only the shifter's high-byte read, not the shared ALU pre-read.
    bad_byte = good.replace('wmask(u_dst_reg_val,', 'wmask(gpr_o[pipe_u_eff.dst],').replace(
        '? u_dst_reg_val\n', '? gpr_o[pipe_u_eff.dst]\n').replace(
        'pipe_u_eff.shrot, u_dst_reg_val,', 'pipe_u_eff.shrot, gpr_o[pipe_u_eff.dst],')
    variants = [
        ('positive', good, 0),
        ('bad-byte', bad_byte, 1),
        ('bad-zero', good.replace("(u_shift_cnt==5'd0) ? u_dst_reg_val", "(u_shift_cnt==5'd0) ? 32'd0"), 1),
        ('bad-memory', good.replace('? mem_rdata : u_dst_reg_val', '? u_dst_reg_val : u_dst_reg_val').replace(
                                   '? mem_rdata : u_src_reg_val', '? u_src_reg_val : u_src_reg_val'), 1),
    ]
    files = [rtl/p for p in ('ventium_pkg.sv', 'core/ventium_alu_pkg.sv', 'core/ventium_decode_pkg.sv',
                            'core/decode.sv', 'core/u_pipe.sv', 'core/uv_common.sv')]
    fixture = Path(__file__).with_name('tb_u_shift_registers.sv')
    shutil.copyfile(Path(__file__), out/'runner-source.py')
    for name,text,expected in variants:
        assert not expected or text != good
        (out/(name+'.sv')).write_text(text)
    for p in [Path(__file__), Path(__file__).with_name('prepare_u_shift_registers.py'),
              Path(__file__).with_name('test_u_shift_registers.py'), fixture,
              parent/'build-started.json', parent/'build-closed.json', *files, *out.glob('*.sv')]:
        pins[str(p)] = sha(p)
    save(out/'started.json', dict(pins=pins, parent=str(parent), invocation=os.environ['INVOCATION_ID'],
        definitions=defs, extra_leaf_definition='VTM_NO_DPI', whole_core=False, gameplay_ipc=None))
    result = dict(passed=False, rows=[], errors=[], whole_core=False, timing_mhz=None, gameplay_ipc=None)
    begin = time.monotonic()
    try:
        for name,_,expected in variants:
            obj = out/(name+'-obj')
            command = [REPO/'tools/verilator_serial.sh', '--binary', '--timing', '--assert',
                '-j', '8', '-sv', '-Wall', '-Wno-UNUSED', '-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+d for d in defs], '+define+VTM_NO_DPI',
                '--Mdir', obj, '--top-module', 'tb_u_shift_registers',
                *files, out/'original_u.sv', out/(name+'.sv'), fixture]
            save(out/(name+'-build-command.json'), list(map(str,command)))
            with (out/(name+'-build.log')).open('x') as log:
                rc = subprocess.run(list(map(str,command)), stdout=log, stderr=subprocess.STDOUT,
                    pass_fds=(9,), timeout=180).returncode
            assert rc == 0, (name,'compile',rc)
            binary = obj/'Vtb_u_shift_registers'
            with (out/(name+'.log')).open('x') as log:
                rc = subprocess.run(['timeout','--kill-after=5s','120s',str(binary)],
                    stdout=log, stderr=subprocess.STDOUT).returncode
            logtext = (out/(name+'.log')).read_text()
            ok = (rc == 0 and 'U-SHIFT-REGISTERS-OK' in logtext) if not expected else (
                rc in (1,-6,134) and 'U-SHIFT-MISMATCH' in logtext and
                'Assertion failed' in logtext and 'U-SHIFT-REGISTERS-OK' not in logtext)
            row = dict(name=name, native_exit=rc, passed=ok,
                log_sha256=sha(out/(name+'.log')), binary_sha256=sha(binary), log=logtext[-1800:])
            result['rows'].append(row)
            assert ok, row
            # Native build/run are closed. Preserve a lossless archive of these
            # two disposable compiler caches so four tiny leaf variants do not
            # accumulate ~640 MiB of PCHs. Never select source, trace or binary.
            caches = [obj/('Vtb_u_shift_registers__pch.h.'+kind+'.gch') for kind in ('fast','slow')]
            assert all(p.is_file() and not p.is_symlink() and p.stat().st_nlink==1 for p in caches)
            cache_hashes = {p.name:sha(p) for p in caches}
            archive = out/(name+'-pch.tar.zst')
            env = {**os.environ,'ZSTD_NBTHREADS':'1'}
            subprocess.run(['tar','--zstd','-cf',archive,'-C',obj,*cache_hashes],env=env,check=True,timeout=60)
            subprocess.run(['tar','--zstd','--compare','-f',archive,'-C',obj],env=env,check=True,timeout=60)
            assert all(sha(obj/p)==h for p,h in cache_hashes.items())
            save(out/(name+'-pch-recovery.json'),dict(hashes=cache_hashes,archive_sha256=sha(archive),
                recovery=['tar','--zstd','-xf',str(archive),'-C',str(obj)]))
            for p in caches:
                p.unlink()
            assert sha(binary)==row['binary_sha256']
        result['passed'] = True
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(p) == h for p,h in pins.items()), seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save(out/'closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
