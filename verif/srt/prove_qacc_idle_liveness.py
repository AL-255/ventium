"""Prove the quotient-liveness invariant of a source-pinned SRT abstraction.

This is not whole-RTL formal equivalence: arithmetic and state-transition
guards shared by both engines are unconstrained common inputs. The native
actual-engine miter separately checks that the real implementation agrees.
"""
import argparse,hashlib,json,os,re,subprocess
from pathlib import Path
from prepare_qacc_idle_payload import PARENT,transform

STATES=['ST_IDLE','ST_DRUN','ST_DFIN','ST_QRUN','ST_QFIN','ST_RRUN','ST_RFIN','ST_RNORM','ST_SPECIAL']

def formula(mutant=None):
    # State encodings are independently checked against the pinned source.
    text='''(set-logic QF_BV)
(declare-const st (_ BitVec 4))
(declare-const entry (_ BitVec 4))
(declare-const reset Bool)
(declare-const finish Bool)
(declare-const oldq (_ BitVec 128))
(declare-const newq (_ BitVec 128))
(declare-const delta (_ BitVec 128))
(define-fun live ((s (_ BitVec 4))) Bool
 (or (= s #x1) (= s #x2) (= s #x5) (= s #x6) (= s #x7)))
(assert (or (= entry #x0) (= entry #x1) (= entry #x3) (= entry #x5) (= entry #x8)))
(assert (=> (live st) (= oldq newq)))
(define-fun nextst () (_ BitVec 4)
 (ite reset #x0
 (ite (= st #x0) entry
 (ite (= st #x1) (ite finish #x2 #x1)
 (ite (= st #x3) (ite finish #x4 #x3)
 (ite (= st #x5) (ite finish #x6 #x5)
 (ite (= st #x6) #x7 #x0)))))))
'''
    # delta is the common quotient digit contribution or RFIN correction;
    # allowing every 128-bit value is stronger than the implemented +/-1/2.
    def update(q,clear):
        return f'''(ite reset {q}
 (ite (= st #x0) (ite {clear} (_ bv0 128) {q})
 (ite (= st #x1) (bvadd {q} delta)
 (ite (= st #x5) (bvadd (bvshl {q} (_ bv2 128)) delta)
 (ite (= st #x6) (bvadd {q} delta) {q})))))'''
    oldclear='(or (= entry #x1) (= entry #x5))'
    newclear='true' if mutant!='missing-rem' else '(not (= entry #x5))'
    old=update('oldq',oldclear);new=update('newq',newclear)
    if mutant=='busy-clear':new=f'(ite (and (not reset) (not (= st #x0))) (_ bv0 128) {new})'
    return text+f'''(define-fun old_next () (_ BitVec 128) {old})
(define-fun new_next () (_ BitVec 128) {new})
(assert (and (live nextst) (not (= old_next new_next))))
(check-sat)
'''

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();source=a.source.resolve(strict=True);out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve()==scratch and out.is_relative_to(scratch)
    assert not out.exists() and __debug__
    old=source.read_text();new=transform(old)
    enum=re.search(r'typedef enum logic \[3:0\] \{([^}]+)\} state_t;',old,re.S)
    assert enum and [s.strip() for s in enum[1].split(',')]==STATES
    assert len(re.findall(r'qacc\s*<=',old))==6 and len(re.findall(r'qacc\s*<=',new))==5
    rows=[]
    for mutant,expected in [(None,'unsat'),('missing-rem','sat'),('busy-clear','sat')]:
        smt=formula(mutant)
        result=subprocess.run(['/usr/bin/z3','-in','-smt2'],input=smt,text=True,capture_output=True,timeout=15)
        assert (result.returncode,result.stdout.strip(),result.stderr)==(0,expected,''),(mutant,result)
        rows.append(dict(mutant=mutant,result=expected,smt2=smt))
    receipt=dict(passed=True,source=str(source),parent_sha256=PARENT,
        candidate_sha256=hashlib.sha256(new.encode()).hexdigest(),
        initial_invariant='Reset enters IDLE, where quotient equality is not required.',
        invariant='Whenever qacc can be consumed, old and new 128-bit qacc agree.',
        abstraction='Common arithmetic contributions and transition predicates are unconstrained.',
        whole_rtl_formal_equivalence=False,native_miter_required=True,runs=rows,
        script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    with out.open('x') as f:json.dump(receipt,f,indent=2)
    print(json.dumps({k:v for k,v in receipt.items() if k!='runs'}))

if __name__=='__main__':main()
