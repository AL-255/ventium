"""Binary bit-vector admission proof, with source-extracted mutant witnesses.

The SMT equations are an explicit mathematical model, not compiled RTL formal
verification. Exact source pins and native replay bind each mutant witness to
the real old/new expressions. This does not prove sequential cache behavior,
X/Z equivalence, whole-core correctness, timing or hardware acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import prepare_parallel_write_admission as recipe

HERE = Path(__file__).resolve().parent
WIDTHS = dict(ADDR_MASK=32, m_addr=32, m_pair_addr=32, m_wstrb=4,
              m_pair_wstrb=4, m_rd_size=2, wq_count=2)
BOOLS = ('idle', 'm_req', 'm_we', 'm_pair_req', 'shutdown', 'fatal_now',
         'wq_head_release', 'pair_quad_ok', 'm_idle', 'rd_deliver', 'm_rd_narrow')
MODES = ('spill', 'shadow', 'v_alias')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def symbolic(quad, mode='none', nonvacuous=False):
    assert mode in ('none', *MODES)
    text = '(set-logic QF_BV)\n(set-option :produce-models true)\n'
    for name, width in WIDTHS.items():
        text += f'(declare-const {name} (_ BitVec {width}))\n'
    for name in BOOLS:
        text += f'(declare-const {name} Bool)\n'
    text += '''
(define-fun shifted ((a (_ BitVec 32)) (s (_ BitVec 4))) (_ BitVec 8)
  (bvshl (concat #x0 s) ((_ zero_extend 6) ((_ extract 1 0) a))))
(define-fun spill ((a (_ BitVec 32)) (s (_ BitVec 4))) Bool
  (not (= ((_ extract 7 4) (shifted a s)) #x0)))
(define-fun base ((a (_ BitVec 32))) (_ BitVec 32) (bvand a #xfffffffc))
(define-fun write_last ((a (_ BitVec 32)) (s (_ BitVec 4))) (_ BitVec 32)
  (bvadd (base a) (ite (spill a s) #x00000007 #x00000003)))
(define-fun outside ((a (_ BitVec 32)) (last (_ BitVec 32))) Bool
  (or (not (= (bvand a (bvnot ADDR_MASK)) #x00000000))
      (not (= (bvand last (bvnot ADDR_MASK)) #x00000000))))
(define-fun old_two () Bool
  (ite m_we (spill m_addr m_wstrb)
    (ite m_rd_narrow false (not (= ((_ extract 1 0) m_addr) #b00)))))
(define-fun old_last () (_ BitVec 32)
  (ite (and m_rd_narrow (not m_we))
    (bvadd m_addr (bvsub (bvshl #x00000001 ((_ zero_extend 30) m_rd_size)) #x00000001))
    (bvadd (base m_addr) (ite old_two #x00000007 #x00000003))))
(define-fun old_u_bad () Bool
  (and m_req (not (bvuge m_addr #xfffe0000)) (outside m_addr old_last)))
(define-fun old_v_bad () Bool
  (and m_req m_we m_pair_req (not (bvuge m_pair_addr #xfffe0000))
    (outside m_pair_addr (write_last m_pair_addr m_pair_wstrb))))
(define-fun single_credit () Bool (or (bvult wq_count #b10) wq_head_release))
(define-fun pair_credit () Bool
  (or (= wq_count #b00) (and (= wq_count #b01) wq_head_release)))
'''
    threshold = '#xfffdffff' if mode == 'shadow' else '#xfffe0000'
    last = '(bvadd (base m_addr) #x00000003)' if mode == 'spill' else '(write_last m_addr m_wstrb)'
    text += f'(define-fun new_u_bad () Bool (and (not (bvuge m_addr {threshold})) (outside m_addr {last})))\n'
    vbad = 'false' if mode == 'v_alias' else \
        '(and (not (bvuge m_pair_addr #xfffe0000)) (outside m_pair_addr (write_last m_pair_addr m_pair_wstrb)))'
    text += f'(define-fun new_v_bad () Bool {vbad})\n'
    credit = '(or pair_credit (and pair_quad_ok single_credit))' if quad else 'pair_credit'
    text += f'(define-fun pair_slots () Bool {credit})\n'
    text += '''
(define-fun old_enq () Bool
  (and idle m_req m_we (not shutdown) (not (or old_u_bad old_v_bad))
    (not fatal_now) (ite m_pair_req pair_slots single_credit)))
(define-fun single_admit () Bool
  (and idle (not shutdown) (not fatal_now) (not new_u_bad) single_credit))
(define-fun pair_admit () Bool
  (and idle (not shutdown) (not fatal_now) (not new_u_bad) (not new_v_bad) pair_slots))
(define-fun new_enq () Bool (and m_req m_we (ite m_pair_req pair_admit single_admit)))
(define-fun ack ((enqueue Bool)) Bool
  (and (not fatal_now) (or rd_deliver enqueue (and shutdown m_idle m_req))))
(define-fun pair_ack ((enqueue Bool)) Bool
  (and (not fatal_now) (or (and enqueue m_pair_req)
    (and shutdown m_idle m_req m_we m_pair_req))))
(define-fun mismatch () Bool
  (or (not (= old_enq new_enq)) (not (= (ack old_enq) (ack new_enq)))
      (not (= (pair_ack old_enq) (pair_ack new_enq)))))
'''
    text += '(assert '+('new_enq' if nonvacuous else 'mismatch')+')\n(check-sat)\n'
    if mode != 'none':
        text += '(get-value ('+' '.join((*WIDTHS, *BOOLS))+'))\n'
    return text


def witness(output):
    assert output.splitlines()[0] == 'sat'
    found = re.findall(r'\((\w+)\s+(true|false|#x[0-9a-f]+|#b[01]+)\)', output)
    result = {}
    for name, value in found:
        assert name not in result and name in (*WIDTHS, *BOOLS)
        result[name] = value == 'true' if value in ('true', 'false') else int(value[2:], 16 if value[1] == 'x' else 2)
    assert result.keys() == set((*WIDTHS, *BOOLS))
    return result


def fixture(old, values, mode):
    assert mode in ('none', *MODES)
    assert sha_text(old) == recipe.PINS['ven_axi_master.sv']
    start = old.index('  logic [7:0]  alias_ssh;')
    aliases = old[start:old.index('  always_ff @(posedge core_clk', start)]
    early = recipe.admission(recipe.enqueue(old))
    early = early[early.index('    logic [31:0] write_alias_last;'):early.index('`ifndef SYNTHESIS')]
    if mode == 'spill':
        early = recipe.once(early, "((alias_ssh[7:4] != 4'd0) ? 32'd7 : 32'd3)", "32'd3")
    elif mode == 'shadow':
        early = recipe.once(early, "!(m_addr >= 32'hFFFE_0000)", "!(m_addr >= 32'hFFFD_FFFF)")
    elif mode == 'v_alias':
        early = recipe.once(early, '!pair_write_alias_bad &&', "1'b1 &&")
    text = 'module tb;\nlocalparam WBUF_CNTW=2, P5_WBUF_DEPTH=2, R_IDLE=0;\n'
    for name, width in WIDTHS.items():
        text += f'reg [{width-1}:0] {name};\n'
    text += 'reg rst, '+', '.join(n for n in BOOLS if n != 'idle')+';\n'
    text += 'wire alias_bad, old_enq, new_enq;\n'
    text += "wire wr_can_pair=(wq_count==0) || ((wq_count==1) && wq_head_release);\n"
    text += aliases+recipe.enqueue(old).replace('wr_enq ', 'old_enq ')+'\n'+early.replace('wr_enq =', 'new_enq =')
    text += '\ninitial begin\n'
    for name, value in values.items():
        if name == 'idle':
            text += f"rst=1'b{int(not value)};\n"
        elif name in WIDTHS:
            text += f"{name}={WIDTHS[name]}'h{value:x};\n"
        else:
            text += f"{name}=1'b{int(value)};\n"
    text += '#1;\n'
    text += "if (old_enq !== new_enq) $fatal(1,\"PROOF-POSITIVE-MISMATCH\");\n" if mode == 'none' else \
        "if (old_enq === new_enq) $fatal(1,\"PROOF-MUTANT-NOT-DETECTED\");\n"
    return text+'$display("PROOF-NATIVE-WITNESS-OK old=%0b new=%0b",old_enq,new_enq); $finish;\nend\nendmodule\n'


def sha_text(text):
    return hashlib.sha256(text.encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--candidate', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, candidate = args.parent.resolve(strict=True), args.candidate.resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert scratch.stat().st_dev != HERE.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0) == {18, 19}
    group = Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0 < int((group/'memory.max').read_text()) <= 512*1024**2
    assert (group/'memory.swap.max').read_text().strip() == '0'
    original = {n:(parent/n).read_text() for n in recipe.PINS}
    changed = recipe.transform(original)
    assert all((candidate/n).read_text() == text for n, text in changed.items())
    assert 'localparam int unsigned P5_WBUF_DEPTH = 2;' in original['ven_axi_master.sv']
    paths = [Path(__file__), Path(recipe.__file__), HERE/'prepare_qualified_pair_credit.py',
             Path('/usr/bin/z3'), Path('/usr/bin/iverilog'), Path('/usr/bin/vvp')]
    paths += [folder/n for folder in (parent, candidate) for n in recipe.PINS]
    pins = {str(p.resolve()):sha(p) for p in paths}
    out.mkdir(mode=0o700)
    def save(name, value):
        with (out/name).open('x') as stream: json.dump(value, stream, indent=2)
    def write(path, text):
        with path.open('x') as stream: stream.write(text)
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
         affinity=sorted(os.sched_getaffinity(0)), sequential_proof=False))
    begin = time.monotonic(); proofs = []; native = []; errors = []
    try:
        for quad in (False, True):
            for mode, nonvacuous in [('none',False), ('none',True), *[(m,False) for m in MODES]]:
                label = f'quad{int(quad)}-'+('nonvacuous' if nonvacuous else mode)
                smt = out/(label+'.smt2'); write(smt, symbolic(quad, mode, nonvacuous))
                result = subprocess.run(['/usr/bin/z3','-T:10','-smt2',str(smt)],
                                        capture_output=True, text=True, timeout=15)
                write(out/(label+'.stdout'), result.stdout); write(out/(label+'.stderr'), result.stderr)
                expected = 'unsat' if mode == 'none' and not nonvacuous else 'sat'
                assert result.returncode == 0 and not result.stderr and result.stdout.splitlines()[0] == expected
                proofs.append(dict(label=label, native_exit=result.returncode, verdict=expected))
                if mode == 'none': continue
                values = witness(result.stdout)
                for check_mode in ('none', mode):
                    tag = label+'-native-'+check_mode
                    sv, binary = out/(tag+'.sv'), out/(tag+'.vvp')
                    write(sv, fixture(original['ven_axi_master.sv'], values, check_mode))
                    command = ['/usr/bin/iverilog','-g2012','-Wall','-s','tb','-DVEN_P54_DUAL_STORE_PAIR',
                        *(['-DVEN_P54_WBUF_QUAD_COMBINE'] if quad else []), '-o',str(binary),str(sv)]
                    with (out/(tag+'.build.log')).open('x') as stream:
                        compiled = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=15)
                    assert compiled.returncode == 0
                    result = subprocess.run(['/usr/bin/vvp',str(binary)], capture_output=True, text=True, timeout=15)
                    write(out/(tag+'.stdout'), result.stdout); write(out/(tag+'.stderr'), result.stderr)
                    assert result.returncode == 0 and not result.stderr and 'PROOF-NATIVE-WITNESS-OK' in result.stdout
                    native.append(dict(label=tag, native_exit=result.returncode, waited=True, values=values,
                                       native_affinity_inherited=sorted(os.sched_getaffinity(0))))
    except Exception as error:
        errors.append(repr(error))
    events = {k:int(v) for k,v in (line.split() for line in (group/'memory.events').read_text().splitlines())}
    stable = all(sha(p) == h for p,h in pins.items())
    result = dict(passed=stable and not errors and len(proofs)==10 and len(native)==12 and
                  not any(events[k] for k in ('oom','oom_kill','oom_group_kill')),
        pins_unchanged=stable, proofs=proofs, native=native, errors=errors,
        seconds=time.monotonic()-begin, memory_events=events, memory_peak=int((group/'memory.peak').read_text()),
        artifacts={str(p):sha(p) for p in out.iterdir() if p.is_file()},
        hand_encoded_binary_model=True, sequential_proof=False, xz_equivalence=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    save('closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('artifacts','native')}), flush=True)
    return int(not result['passed'])


if __name__ == '__main__': raise SystemExit(main())
