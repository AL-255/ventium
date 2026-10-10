#!/usr/bin/env python3
"""Exercise the real FPGA wrapper's UV/fast source guards without Vivado.

Usage: python3 -B fpga/test_uv_fast_profile.py FROZEN_BUILD
Scratch is created only in the explicitly supplied external TMPDIR.
This tests launch policy, not hardware execution or total U+V IPC.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    frozen = Path(sys.argv[1]).resolve(strict=True)
    here = Path(__file__).resolve().parent
    scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch == Path('/home/yukidama/external/tmp').resolve(strict=True)
    defines = (frozen/'defines.txt').read_text().splitlines()
    shim = (frozen/'ventium/ao486-sim/ven/ven_ao486_shim.sv').read_text()
    knobs = ('VEN_FPGA_FASTPATH', 'VEN_FPGA_RELOC_FASTPATH', 'VEN_FPGA_FASTLOAD',
             'VEN_FPGA_FASTSTORE', 'VEN_FPGA_BOUNDED_FASTMEM')
    required = ('VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
                'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTLOAD_BOUNDED',
                'VEN_SYS_FASTSTORE_FLAT', 'VEN_FP_PIPE', 'VEN_FP_PIPE2')
    cases = 0
    with tempfile.TemporaryDirectory(prefix='ventium-uv-fast-test.', dir=scratch) as directory:
        root = Path(directory)
        source = root/'source'
        test_shim = source/'ao486-sim/ven/ven_ao486_shim.sv'
        test_shim.parent.mkdir(parents=True)
        # Posted profiles require the actual bridge source alongside the shim.
        # Preserve that admission check; the old fixture predated this profile.
        if 'VEN_DDR_POSTED' in defines:
            (source/'fpga').mkdir()
            shutil.copyfile(frozen/'ventium/fpga/ven_ddram_axi_posted.sv',
                            source/'fpga/ven_ddram_axi_posted.sv')
        profile = root/'defines.txt'

        def run(label, defs=defines, body=shim, override=None, rejection=None):
            nonlocal cases
            profile.write_text('\n'.join(defs)+'\n')
            test_shim.write_text(body)
            env = dict(os.environ)
            for name in knobs:
                env.pop(name, None)
            env.update(override or {})
            result = subprocess.run(['tclsh', str(here/'test_rk_wrapper.tcl'),
                str(here/'create_project_3mhz_wrapper.tcl'), str(frozen/'flow'),
                str(profile), str(source), str(frozen/'template')],
                env=env, capture_output=True, text=True, timeout=10)
            output = result.stdout+result.stderr
            if rejection is None:
                assert result.returncode == 0 and 'UV-FAST-SOURCE-CONTRACT-OK' in output, (label, output)
            else:
                assert result.returncode != 0 and rejection in output, (label, output)
            cases += 1

        run('full UV/fast profile')
        for name in required:
            assert name in defines
            run('missing '+name, defs=[d for d in defines if d != name],
                rejection='profile is missing '+name)
        for name in knobs:
            run('disabled '+name, override={name: '0'},
                rejection='mandatory UV+fast-pipe mode forbids '+name+'=0')
        connection = ".cycle_mode (1'b1)"
        assert shim.count(connection) == 1
        for replacement in (".cycle_mode (1'b0)", '.cycle_mode (dynamic_mode)',
                            '// '+connection, '/* '+connection+' */'):
            run('reject '+replacement, body=shim.replace(connection, replacement),
                rejection="requires cycle_mode=1'b1")
        run('comment cannot substitute', body=shim.replace(connection, ".cycle_mode (1'b0)")+
            '\n// '+connection+'\n', rejection="requires cycle_mode=1'b1")
        run('two connections', body=shim+'\n'+connection, rejection="requires cycle_mode=1'b1")
        run('unknown extra define', defs=defines+['VEN_UNREVIEWED_EXTENSION'],
            rejection='wrong define count')
        if len(defines) == 113:
            fe = ['VEN_FE_PIPE', 'VEN_FE_DTLB_MULTI', 'VEN_FE_DTLB_PERM']
            assert defines[107:110] == fe
            for name in fe:
                run('missing '+name, defs=[d for d in defines if d != name],
                    rejection='wrong define count')
            wrong_order = defines.copy()
            wrong_order[107], wrong_order[108] = wrong_order[108], wrong_order[107]
            run('FE order changed', defs=wrong_order, rejection='wrong FE-DTLB extension bundle/order')
            unsupported = defines.copy()
            # Preserve length and required fast-mode definitions: the refusal
            # must come from the incompatible experiment, not another guard.
            assert 'VEN_L2_PERF' in unsupported
            unsupported[unsupported.index('VEN_L2_PERF')] = 'VEN_PIPE_MEM_CHAIN'
            run('FE memory-chain owner unsupported', defs=unsupported,
                rejection='unverified FE-DTLB memory-chain profile')
    print(f'UV-FAST-PROFILE-GUARDS-OK cases={cases}; no Vivado, no hardware acceptance')


if __name__ == '__main__':
    main()
