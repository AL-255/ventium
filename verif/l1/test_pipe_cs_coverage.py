"""Regrade native CS witnesses and reject lost-request/owner/fault evidence."""
import json
import os
from pathlib import Path
import re
import subprocess
import unittest

import build_cs_extent_observer as observer
import prepare_pipe_cs_interior as interior
from run_pipe_cs_coverage import observations, sha


class Coverage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root=Path(os.environ['PIPE_CS_COVERAGE']).resolve(strict=True)
        cls.before=json.loads((cls.root/'started.json').read_text())
        cls.done=json.loads((cls.root/'closed.json').read_text())
        assert cls.done['passed'] and cls.done['pins_unchanged'] and not cls.done['errors']
        assert all(sha(p)==h for p,h in cls.before['pins'].items())

    def test_all_native_witnesses(self):
        self.assertEqual(self.done['runs'],288)
        self.assertEqual(len(self.done['rows']),72)
        for row in self.done['rows']:
            folder=self.root/(row['name']+'-'+'-'.join(map(str,row['case'])))
            path=folder/f"observer-on-l{row['latency']}-{row['mode']}.stderr"
            got=observations(path.read_text(),row['case'][0],row['name']=='interior')
            self.assertEqual(got,{k:row[k] for k in got})

    def test_request_and_held_mutants(self):
        text=(self.root/'interior-0-6/observer-on-l7-cycle.stderr').read_text()
        self.assertIn('load=1',text)
        mutants=[text.replace('load=1','load=0'), text.replace('active=1','active=0'),
                 text.replace('held_pc=8030','held_pc=8031'),text.replace('ack=1 commit=1','ack=0 commit=1'),
                 text.replace('boundary=0','boundary=1'),text.replace('frontend=1','frontend=0')]
        for changed in mutants:
            self.assertNotEqual(changed,text)
            with self.assertRaises(AssertionError): observations(changed,0,True)

    def test_no_boundary_side_effects(self):
        text=(self.root/'boundary-1-6-1/observer-on-l7-cycle.stderr').read_text()
        self.assertTrue(observations(text,1,False)['checked_boundary_clocks'])
        for old,new in (('store=0','store=1'),('active=0','active=1'),('commit=0','commit=1')):
            with self.assertRaises(AssertionError): observations(text.replace(old,new),1,False)
        with self.assertRaises(AssertionError): observations('',1,False)

    def test_interior_layout_and_mutants(self):
        fixtures=Path(os.environ['PIPE_CS_INTERIOR']).resolve(strict=True)
        done=json.loads((fixtures/'closed.json').read_text())
        self.assertEqual(len(done['cases']),6)
        for row in done['cases']:
            symbols=row['symbols']; want=row['expected']; case=(want['kind'],want['length'])
            data=Path(row['image']).read_bytes()
            self.assertEqual(interior.audit_image(data,symbols,case),want)
            for address in (symbols['probe_insn']-0xf0000, symbols['probe_after']-0xf0000+1,
                            data.index(bytes.fromhex('66c70618053f800000'))+5,0xfff0):
                changed=bytearray(data); changed[address]^=1
                with self.assertRaises(AssertionError): interior.audit_image(changed,symbols,case)

    def test_read_only_observer_delta(self):
        candidate=Path(self.before['models']['candidate']).parent.parent
        build=json.loads((candidate/'build-started.json').read_text())
        source=Path(build['host']).read_text(); changed=observer.instrument(source)
        # Exactly one inserted block, no replaced host operation.
        begin=source.index(observer.ANCHOR)
        added=changed[begin:len(changed)-(len(source)-begin)]
        self.assertEqual(changed[:begin]+changed[begin+len(added):],source)
        self.assertNotIn('eval(',added)
        self.assertFalse(re.search(r'->\w+\s*(?:=(?!=)|\+=|-=|\+\+|--)',added))
        self.assertIn('std::exit(2)',added)  # overflow is never silent

    def test_boundary_arithmetic_lemma(self):
        # Mathematical QF_BV lemma, NOT automatic RTL translation. Check the
        # actual frontend source anchors separately to justify its application.
        candidate=Path(self.before['models']['candidate']).parent.parent
        source=(candidate/'candidate/rtl/core/core.sv').read_text()
        for text in (
            "({1'b0,eip} + 33'd15 > {1'b0,seg_limit[SG_CS]})",
            'assign pipe_fetch_checked_handoff = !pipe_mem_active_q &&',
            '(sfetch_boundary || !if_auth_ok)',
            'pipe_frontend_ready = pipe_bytes_ok && !pipe_fetch_checked_handoff;',
        ): self.assertIn(text,source)
        problem='''(set-logic QF_BV)
(declare-const pc (_ BitVec 32))
(declare-const lim (_ BitVec 32))
(declare-const len (_ BitVec 4))
(define-fun first () (_ BitVec 33) ((_ zero_extend 1) pc))
(define-fun limit () (_ BitVec 33) ((_ zero_extend 1) lim))
(define-fun last () (_ BitVec 33) (bvsub (bvadd first ((_ zero_extend 29) len)) (_ bv1 33)))
(assert (bvule (bvadd first (_ bv15 33)) limit))
(assert (bvugt last limit))
'''
        for restriction,want in (('(assert (not (= len #x0)))','unsat'),
                                 ('(assert (= len #x0))\n(assert (= pc #x00000000))','sat')):
            result=subprocess.run(['/usr/bin/z3','-in'],input=problem+restriction+'\n(check-sat)\n',
                                  text=True,capture_output=True,timeout=10,check=True)
            self.assertEqual(result.stdout.strip(),want)


if __name__=='__main__': unittest.main()
