"""Scope checks and exact request-cofactor lemma; native RTL gates are separate."""
import hashlib
import os
from pathlib import Path
import subprocess
import unittest

import prepare_pipe_mem_cs_extent as recipe
from prove_pipe_mem_cs_extent import problem, QUERIES


class PipeMemoryCS(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ['PIPE_CS_SOURCE']).read_text()
        cls.changed = recipe.transform(cls.source)

    def test_exact_scope_and_reversal(self):
        restored = self.changed
        for old,new in reversed(recipe.edits(self.source)):
            self.assertEqual(restored.count(new),1)
            restored=restored.replace(new,old)
        self.assertEqual(restored,self.source)
        self.assertIn(hashlib.sha256(restored.encode()).hexdigest(),recipe.PARENTS)

    def test_reject_drift_and_double_application(self):
        for bad in (self.source+'\n',self.changed,self.source.replace('33\'d1','32\'d1',1)):
            with self.assertRaises(ValueError):recipe.transform(bad)

    def test_global_fault_delivery_and_held_owners_unchanged(self):
        start=self.source.index('    cs_extent_fault = sys_mode')
        end=self.source.index('\n  end',start)
        self.assertIn(self.source[start:end],self.changed)
        for name in ('pipe_load_req','pipe_store_req'):
            import re
            before=re.findall(r'^    '+name+r'\s*=.*?;\n',self.source,re.M|re.S)
            self.assertEqual(len(before),1)
            self.assertIn(before[0],self.changed)
        self.assertIn('pipe_new_load_req === cs_reference_pipe_new_load_req',self.changed)
        self.assertIn('pipe_new_store_req === cs_reference_pipe_new_store_req',self.changed)
        self.assertNotIn('always_ff',recipe.ADDED)

    def test_symbolic_lemma_and_required_counterexamples(self):
        for name,formula,expected in QUERIES:
            with self.subTest(query=name):
                result=subprocess.run(['/usr/bin/z3','-in','-smt2'],
                    input=problem()+'(assert '+formula+')\n(check-sat)\n',
                    text=True,capture_output=True,timeout=10)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stderr,'')
                self.assertEqual(result.stdout.strip(),expected)


if __name__=='__main__':unittest.main()
