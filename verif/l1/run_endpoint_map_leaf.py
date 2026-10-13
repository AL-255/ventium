"""Bounded exact-source endpoint-map miter and symbolic address proof.

Checks the actual ven_cachemap and old/new seam expressions. This is neither
a sequential cache proof nor core, timing, standard-suite or FPGA acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time

import prepare_endpoint_map as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
PORTS = '''#(parameter logic [31:0] ADDR_MASK=32'hffffffff,
    parameter bit CMAP_SNAPSHOT_USER_HIGHMEM=0)(
    input logic [31:0] core_addr,
    input logic core_we, smm_active, core_clk, seam_core_rst_n,
    input logic [3:0] core_wstrb,
    input logic [55:0] NB_PAM,
    input logic [7:0] NB_DRAMC, NB_CC, NB_TOM_MB4, NB_SMRAM,
    output logic [51:0] result);
'''


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def cut(text, begin, end):
    if text.count(begin) != 1 or text.count(end) != 1:
        raise ValueError('endpoint-map extraction anchor drift')
    start = text.index(begin)
    return text[start:text.index(end, start)]


def leaf(text, module):
    first = cut(text, '  logic core_d_l1c, core_d_dram_u, core_d_l2c_u;',
                '  // REVIEW1_Aug3 R2-H02: classify')
    extent = cut(text, '  logic [2:0]  core_d_hi;',
                 '  logic mc_next_l1c, mc_next_dram, mc_next_l2c, mc_next_enable, mc_next_ready;')
    assert extent.endswith('`ifdef VEN_PIPE_MEM_CHAIN\n')
    extent = extent.removesuffix('`ifdef VEN_PIPE_MEM_CHAIN\n')
    tail = cut(text, '  logic core_d_l1c_last, core_d_dram_last_u, core_d_l2c_last_u;',
               '  // AXI master / CDC.')
    route = cut(text, '      logic ep_ok_first, ep_ok_last;',
                '      assign route_bad = core_req && core_route_deny')
    return ('module '+module+' '+PORTS+first+extent+tail+
            '  logic core_route_deny;\n'+route+'''
  assign result = {core_d_last,
      core_d_dram_u, core_d_l1c, core_d_l2c_u, core_d_region,
      core_d_dram_last_u, core_d_l1c_last, core_d_l2c_last_u, core_d_region_last,
      ep_ok_first, ep_ok_last, pci_ok_first, pci_ok_last, core_route_deny,
      (core_d_l1c && core_d_l1c_last)};
endmodule
''')


def symbolic():
    return '''(set-logic QF_BV)
(declare-const addr (_ BitVec 32))
(declare-const strobe (_ BitVec 4))
(declare-const we Bool)
(declare-const mask (_ BitVec 32))
(define-fun hi () (_ BitVec 2)
  (ite (= ((_ extract 3 3) strobe) #b1) #b11
  (ite (= ((_ extract 2 2) strobe) #b1) #b10
  (ite (= ((_ extract 1 1) strobe) #b1) #b01 #b00))))
(define-fun delta () (_ BitVec 2) (ite (or we (not (= strobe #x0))) hi #b11))
(define-fun last_addr () (_ BitVec 32) (bvadd addr ((_ zero_extend 30) delta)))
(define-fun line_end () (_ BitVec 6)
  (bvadd ((_ zero_extend 1) ((_ extract 4 0) addr)) ((_ zero_extend 4) delta)))
(define-fun crosses () Bool (= ((_ extract 5 5) line_end) #b1))
(define-fun next_line () (_ BitVec 32)
  (concat (bvadd ((_ extract 31 5) addr) (_ bv1 27)) #b00000))
(define-fun chosen () (_ BitVec 32) (ite crosses next_line addr))
(define-fun whole_line_mask () Bool (= (bvand mask #x0000001f) #x0000001f))
(define-fun aperture ((a (_ BitVec 32))) Bool
  (or (= (bvand a (bvnot mask)) #x00000000) (bvuge a #xfffe0000)))
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    parent = args.parent.resolve(strict=True); root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 4*1024**3
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    original = (parent/recipe.FILE).read_text(); changed = recipe.transform(original)
    cachemap = parent/'rtl/northbridge/ven_cachemap.sv'
    assert sha(cachemap) == recipe.CACHEMAP
    control = leaf(original, 'endpoint_control')
    candidate = leaf(changed, 'endpoint_candidate')
    template = HERE/'tb_endpoint_map.sv'
    pins = {str(p.resolve()): sha(p) for p in (
        Path(__file__), Path(recipe.__file__), template, parent/recipe.FILE, cachemap,
        REPO/'tools/build_scope.sh', REPO/'tools/verilator_serial.sh',
        Path(os.environ['VENTIUM_VERILATOR_BIN']), Path('/usr/bin/z3'))}
    root.mkdir()
    def save(name, value):
        with (root/name).open('x') as stream:
            json.dump(value, stream, indent=2)
    def write(path, text):
        with path.open('x') as stream:
            stream.write(text)
        pins[str(path)] = sha(path)
    path = root/'candidate'/recipe.FILE; path.parent.mkdir(parents=True)
    write(path, changed)
    save('started.json', dict(pins=pins, invocation=os.environ.get('INVOCATION_ID'),
         affinity=sorted(os.sched_getaffinity(0)), source_scope=__doc__))
    start = time.monotonic(); rows = []; proofs = []
    done = dict(passed=False, whole_core=False, hardware_acceptance=False,
                standard_suite=False, timing_measured=False, gameplay_ipc=None)
    try:
        queries = [
            ('same-line', '(not (= ((_ extract 31 5) last_addr) ((_ extract 31 5) chosen)))', 'unsat'),
            ('same-aperture', '(and whole_line_mask (not (= (aperture last_addr) (aperture chosen))))', 'unsat'),
            ('unsafe-first-only', '(not (= ((_ extract 31 5) last_addr) ((_ extract 31 5) addr)))', 'sat'),
            ('unsafe-subline-mask', '(not (= (aperture last_addr) (aperture chosen)))', 'sat'),
            ('wrap-is-exercisable', '(and crosses (bvult last_addr addr) (= next_line #x00000000))', 'sat')]
        for name, formula, expected in queries:
            path = root/(name+'.smt2')
            write(path, symbolic()+'(assert '+formula+')\n(check-sat)\n')
            result = subprocess.run(['/usr/bin/z3', path], capture_output=True, text=True, timeout=20)
            write(root/(name+'.log'), result.stdout+result.stderr)
            assert result.returncode == 0 and not result.stderr and result.stdout.strip() == expected, name
            proofs.append(dict(name=name, native_exit=0, result=expected))

        def mutate(old, new):
            assert candidate.count(old) == 1
            return candidate.replace(old, new)
        variants = [('positive', candidate),
            ('lost-tail-map', mutate('      core_d_line_end[5]\n', "      1'b0\n")),
            ('lost-mask-fallback', mutate("if ((ADDR_MASK & 32'h1f) == 32'h1f)", "if (1'b1)")),
            ('lost-zero-read-extent', mutate("? {3'd0, core_d_hi} : 6'd3)", "? {3'd0, core_d_hi} : 6'd0)"))]
        assert len({text for _, text in variants}) == len(variants)
        for name, text in variants:
            assert shutil.disk_usage(root).free > 4*1024**3
            folder = root/name; folder.mkdir()
            source = folder/'miter.sv'; write(source, control+text+template.read_text())
            command = [str(REPO/'tools/verilator_serial.sh'), '--binary', '--timing', '--assert',
                '-sv', '-j', '32', '-Wall', '-Wno-UNUSED', '-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '+define+SYNTHESIS', '--top-module', 'tb_endpoint_map',
                '--Mdir', str(folder/'obj'), '-o', 'test', str(cachemap), str(source)]
            row = dict(name=name, command=command); rows.append(row)
            with (folder/'build.log').open('x') as log:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                    env=dict(os.environ, CCACHE_DISABLE='1'), pass_fds=(9,), timeout=150)
            row['build_exit'] = result.returncode
            assert result.returncode == 0, name+' compile failed'
            with (folder/'run.log').open('x') as log:
                result = subprocess.run([folder/'obj/test'], stdout=log, stderr=subprocess.STDOUT, timeout=90)
            row['native_exit'] = result.returncode
            log = (folder/'run.log').read_text(); row['log'] = log
            if name == 'positive':
                assert result.returncode == 0 and 'ENDPOINT-MAP-OK vectors=720896 checks=11534336' in log, log
                assert not re.search(r'Error|FATAL|MISMATCH', log), log
            else:
                assert result.returncode in (-6, 1, 134) and 'ENDPOINT-MAP-MISMATCH' in log, log
            row['artifacts'] = {str(p):sha(p) for p in
                (source, folder/'build.log', folder/'run.log', folder/'obj/test')}
            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts')}), flush=True)
        done['passed'] = True
    except Exception as error:
        done['error'] = repr(error)
    done.update(rows=rows, queries=proofs, pins=pins,
        pins_unchanged=all(sha(p)==h for p,h in pins.items()), seconds=time.monotonic()-start)
    done['passed'] &= done['pins_unchanged']
    save('closed.json', done)
    print(json.dumps({k:v for k,v in done.items() if k not in ('rows','pins')}), flush=True)
    return 0 if done['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
