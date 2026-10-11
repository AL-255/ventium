"""Bit-vector proof and actual SV arithmetic tests; not whole-core qualification."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import prepare_fetch_fault_page as patch


FORMAL = '''(set-logic QF_BV)
(declare-const a (_ BitVec 32))
(declare-const n (_ BitVec 5))
(define-fun total () (_ BitVec 13)
 (bvadd ((_ zero_extend 1) ((_ extract 11 0) a)) ((_ zero_extend 8) n)))
(define-fun before () Bool (= total (_ bv0 13)))
(define-fun after () Bool (bvugt total (_ bv4096 13)))
(define-fun old () (_ BitVec 32)
 (bvand (bvsub (bvadd a ((_ zero_extend 27) n)) (_ bv1 32)) #xfffff000))
(define-fun current () (_ BitVec 20) ((_ extract 31 12) a))
(define-fun next () (_ BitVec 20) (bvadd current (_ bv1 20)))
(define-fun previous () (_ BitVec 20) (bvsub current (_ bv1 20)))
(define-fun new () (_ BitVec 32)
 (concat (ite before previous (ite after next current)) #x000))
(define-fun crossed () Bool (not (= ((_ extract 31 12) old) current)))
'''


TB = '''`timescale 1ns/1ps
module tb;
  reg [31:0] flin;
  reg [4:0] d_fetch_fault_len;
  wire [31:0] fetch_fault_linear, old_page, fetch_fault_page;
  assign fetch_fault_linear = flin + {27'd0,d_fetch_fault_len} - 32'd1;
  assign old_page = {fetch_fault_linear[31:12],12'd0};
NEW
  wire old_cross = (old_page[31:12] != flin[31:12]);
  wire new_cross = (fetch_fault_before_page || fetch_fault_after_page);
  reg [19:0] pages[0:7];
  integer count=0;
  initial begin
    pages[0]=20'h00000; pages[1]=20'h00001; pages[2]=20'h00007; pages[3]=20'h000ff;
    pages[4]=20'h0ffff; pages[5]=20'h7ffff; pages[6]=20'hffffe; pages[7]=20'hfffff;
    for (integer p=0;p<8;p=p+1)
      for (integer offset=0;offset<4096;offset=offset+1)
        for (integer len=0;len<32;len=len+1) begin
          flin={pages[p],12'(offset)};
          d_fetch_fault_len=5'(len);
          #1;
          if (fetch_fault_page !== old_page || new_cross !== old_cross)
            $fatal(1,"page mismatch a=%h n=%d old=%h new=%h",flin,d_fetch_fault_len,old_page,fetch_fault_page);
          count=count+1;
        end
    if (count!=1048576) $fatal(1,"wrong coverage count");
    $display("FETCH-FAULT-PAGE-OK combinations=%0d",count);
    $finish;
  end
endmodule
'''


class FetchFaultPage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source_path = Path(os.environ['FETCH_FAULT_PARENT']).resolve(strict=True)
        cls.source = cls.source_path.read_text()
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        assert Path(os.environ['TMPDIR']).resolve() == scratch
        cls.out = Path(tempfile.mkdtemp(prefix='ventium-fetch-fault-page-leaf.', dir=scratch))
        cls.receipts = []

    def command(self, name, argv, expected=0, text=None):
        completed = subprocess.run(argv, input=text, capture_output=True, text=True, timeout=30)
        (self.out/(name+'.stdout')).write_text(completed.stdout)
        (self.out/(name+'.stderr')).write_text(completed.stderr)
        if text is not None:
            (self.out/(name+'.smt2')).write_text(text)
        self.receipts.append(dict(name=name, command=list(map(str, argv)), native_exit=completed.returncode,
            actual_wait=True, stdout_sha256=hashlib.sha256(completed.stdout.encode()).hexdigest(),
            stderr_sha256=hashlib.sha256(completed.stderr.encode()).hexdigest()))
        self.assertEqual(completed.returncode, expected, completed.stdout+completed.stderr)
        return completed.stdout.strip()

    def test_01_exact_source_scope(self):
        changed = patch.transform(self.source)
        self.assertEqual(changed.replace(patch.NEW, patch.OLD).replace(patch.PROBE_NEW, patch.PROBE_OLD), self.source)
        self.assertIn(patch.NEW, changed)
        for bad in (self.source+'\n', changed):
            with self.assertRaises(ValueError):
                patch.transform(bad)

    def test_02_all_addresses_and_lengths(self):
        tests = (
            ('page-identity', '(not (= old new))', 'unsat'),
            ('cross-identity', '(not (= crossed (or before after)))', 'unsat'),
            ('missing-underflow-mutant', '(not (= old (concat (ite after next current) #x000)))', 'sat'),
            ('wrong-boundary-mutant', '(not (= old (concat (ite before previous (ite (bvuge total (_ bv4096 13)) next current)) #x000)))', 'sat'),
            ('narrow-carry-mutant', '(and after (not (= old (concat #b0 (bvadd ((_ extract 18 0) current) (_ bv1 19)) #x000))))', 'sat'),
        )
        for name, assertion, expected in tests:
            with self.subTest(name=name):
                actual = self.command(name, ['/usr/bin/z3', '-in', '-smt2'],
                    text=FORMAL+'(assert '+assertion+')\n(check-sat)\n')
                self.assertEqual(actual, expected)

    def test_03_actual_sv_and_mutants(self):
        changed = patch.transform(self.source)
        self.assertEqual(changed.count(patch.NEW), 1)
        variants = (
            ('candidate', patch.NEW, 0),
            ('wrong-boundary', patch.NEW.replace('> 13\'d4096', '>= 13\'d4096'), 1),
            ('missing-underflow', patch.NEW.replace('(fetch_fault_end == 13\'d0)', "1'b0"), 1),
        )
        for label, body, expected in variants:
            sv = self.out/(label+'.sv')
            sv.write_text(TB.replace('NEW', body))
            binary = self.out/(label+'.vvp')
            self.command(label+'-compile', ['/usr/bin/iverilog', '-g2012', '-s', 'tb', '-o', str(binary), str(sv)])
            output = self.command(label+'-run', ['/usr/bin/vvp', str(binary)], expected)
            if expected == 0:
                self.assertIn('FETCH-FAULT-PAGE-OK combinations=1048576', output)

    @classmethod
    def tearDownClass(cls):
        pins = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in
                (Path(__file__), Path(patch.__file__), cls.source_path)}
        assert pins[str(cls.source_path)] == patch.PARENT
        # The outer unittest native exit is the pass/fail authority, not this
        # evidence listing (tearDown also runs after an individual test fails).
        (cls.out/'evidence.json').write_text(json.dumps(dict(pins=pins, commands=cls.receipts,
            invocation=os.environ.get('INVOCATION_ID'), whole_core_verified=False,
            fmax=None, gameplay_ipc=None), indent=2))
        print('FETCH_FAULT_PAGE_EVIDENCE='+str(cls.out), flush=True)


if __name__ == '__main__':
    unittest.main()
