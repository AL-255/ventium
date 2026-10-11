"""Symbolic cofactor proof; full cache behavior is tested separately."""
import hashlib
import os
from pathlib import Path
import subprocess
import unittest

import prepare_pair_ready_cofactor as patch


def formal():
    text = '(set-logic QF_BV)\n'
    flags = ('rst req we cache golden flush snoop idle early stream credit rd '
             'next_req prime_extra wh sh current_hit prime_hit code ack pair_req '
             'chain load_store windows shadow code_buffer').split()
    for name in flags:
        text += f'(declare-const {name} Bool)\n'
    for name, width in (('offset', 5), ('next_offset', 5), ('v_offset', 5),
                        ('strb', 4), ('next_strb', 4), ('v_strb', 4), ('lanes', 2)):
        text += f'(declare-const {name} (_ BitVec {width}))\n'
    def term(name, body, kind='Bool'):
        nonlocal text
        text += f'(define-fun {name} () {kind} {body})\n'
    term('lookup', '(and chain next_req (not early) (not stream) '
         '(or (and req (not we) rd idle) (and (not req) prime_extra)))')
    term('hit', '(ite lookup prime_hit current_hit)')
    term('addr', '(ite lookup next_offset offset)', '(_ BitVec 5)')
    term('mask', '(ite lookup next_strb strb)', '(_ BitVec 4)')
    term('hi', '(ite (= ((_ extract 3 3) mask) #b1) #b000011 '
         '(ite (= ((_ extract 2 2) mask) #b1) #b000010 '
         '(ite (= ((_ extract 1 1) mask) #b1) #b000001 #b000000)))', '(_ BitVec 6)')
    term('xline', '(bvugt (bvadd ((_ zero_extend 1) addr) '
         '(ite (or we (not (= mask #x0))) hi #b000011)) #b011111)')
    term('no_code', '(not (and code_buffer code))')
    term('reuse_qual', '(and (not lookup) (not stream) (not early) idle req '
         '(not we) cache (not golden) (not flush) (not snoop) hit no_code '
         '(bvule offset #b11100))')
    term('window', '(and windows wh reuse_qual)')
    term('saved', '(and windows shadow sh reuse_qual)')
    term('shape', '(and (= ((_ extract 1 0) offset) #b00) '
         '(= ((_ extract 1 0) v_offset) #b00) '
         '(not (= ((_ extract 4 2) offset) ((_ extract 4 2) v_offset))) '
         '(= strb #xf) (= v_strb #xf))')
    term('common', '(and rst req cache (not golden) (not flush) (not snoop) idle '
         '(not stream) shape)')
    term('old', '(and common (not lookup) (not xline) '
         '(ite load_store (ite we credit (and (or rd window saved) hit '
         '(not early) no_code)) (and we credit)))')
    term('read_identity', '(or rd (and windows wh) (and windows shadow sh))')
    term('read_guard', '(not (and chain next_req rd))')
    term('new', '(and common (ite load_store (ite we credit '
         '(and read_identity current_hit (not early) no_code read_guard)) (and we credit)))')
    term('capture_common', '(and (= lanes #b10) req we ack cache (not golden) '
         'idle (not stream) (not early) (not flush) (not snoop) (not pair_req) '
         '(= ((_ extract 1 0) offset) #b00) (= strb #xf))')
    term('old_capture', '(and capture_common (not lookup) (not xline))')
    return text


class PairReadyCofactor(unittest.TestCase):
    def test_01_exact_source_scope(self):
        parent = Path(os.environ['PAIR_READY_PARENT']).read_text()
        changed = patch.transform(parent)
        for pattern, replacement, name in (
                (patch.READY_PATTERN, patch.NEW_READY, 'c_pair_ready'),
                (patch.CAPTURE_PATTERN, patch.NEW_CAPTURE, 'pair_store_read_capture')):
            old = patch.extract(parent, pattern)
            self.assertEqual(changed.count(replacement), 1)
            changed = changed.replace(replacement+patch.witness(old, name), old)
        self.assertEqual(changed, parent)
        for bad in (parent+'\n', patch.transform(parent)):
            with self.assertRaises(ValueError):
                patch.transform(bad)

    def test_02_all_binary_states_and_configurations(self):
        cases = [('ready', '(not (= old new))', 'unsat'),
                 ('capture', '(not (= old_capture capture_common))', 'unsat'),
                 ('missing-next-exclusion', '(and common load_store (not we) '
                  'read_identity current_hit (not early) no_code (not old))', 'sat'),
                 ('missing-residency', '(and common load_store (not we) '
                  'read_identity (not early) no_code read_guard (not old))', 'sat'),
                 ('selected-tag-mutant', '(and common load_store (not we) '
                  'read_identity prime_hit (not early) no_code read_guard (not old))', 'sat')]
        out = Path(os.environ['PAIR_READY_PROOF_OUT'])
        out.mkdir()
        for name, assertion, expected in cases:
            problem = formal()+'(assert '+assertion+')\n(check-sat)\n'
            (out/(name+'.smt2')).write_text(problem)
            result = subprocess.run(['/usr/bin/z3', '-in', '-smt2'], input=problem,
                                    text=True, capture_output=True, timeout=30)
            (out/(name+'.stdout')).write_text(result.stdout)
            (out/(name+'.stderr')).write_text(result.stderr)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected, name)
        print('PAIR-READY-SYMBOLIC-OK all binary states/configurations; 3 mutants detected')


if __name__ == '__main__':
    unittest.main()
