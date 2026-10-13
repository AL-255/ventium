"""Fail-closed source recipe checks; no core/timing acceptance."""
import os
import ast
from pathlib import Path
import re
import unittest

import prepare_prime_reg_flags as recipe
import run_prime_reg_flags_leaf as leaf
import prove_prime_reg_flags as proof
import run_prime_cs_core as prior
import run_prime_reg_flags_core as current
from run_prime_reg_flags_corners import fixture

ROOT=Path(os.environ.get('PRIME_REG_ROOT',
    '/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI')).resolve(strict=True)


class Recipe(unittest.TestCase):
    def setUp(self):
        self.sources={n:(ROOT/'prime-cs-core-r1/candidate/rtl/core'/n).read_text()
                      for n in recipe.PARENTS}

    def test_exact_single_consumer(self):
        new=recipe.transform(self.sources)
        old=self.sources['core_mem_chain.svh']
        commit=recipe.commit(old)
        self.assertEqual(new.count(commit.replace('v_br_taken_eff','mc_reg_v_br_taken')),1)
        self.assertEqual(new.count(recipe.ADDED),1)
        start=new.index('`ifndef SYNTHESIS\n  logic mc_pipeline_commit_before_reg_flags;')
        stop=new.index('`endif\n',start)+len('`endif\n')
        recovered=new[:start]+new[stop:]
        recovered=recovered.replace(recipe.ADDED,'').replace(
            commit.replace('v_br_taken_eff','mc_reg_v_br_taken'),commit)
        self.assertEqual(recovered,old)
        self.assertIn('.u_alu(), .u_flags(mc_reg_u_flags)',recipe.ADDED)
        self.assertIn('.u_sh(), .u_shm1(), .u_shcf(), .u_shcnt()',recipe.ADDED)
        self.assertNotIn('mem_rdata',recipe.ADDED)

    def test_source_drift_and_reapplication_rejected(self):
        for name in recipe.PARENTS:
            source=dict(self.sources);source[name]+='\n'
            with self.assertRaises(ValueError):recipe.transform(source)
        source=dict(self.sources);source['core_mem_chain.svh']=recipe.transform(source)
        with self.assertRaises(ValueError):recipe.transform(source)

    def test_guards_are_source_bound(self):
        for lane in ('u','v'):
            rows=re.findall(r'^  assign mc_prime_'+lane+r'_branch = (.*?);\n',
                            self.sources['core_mem_chain.svh'],re.M|re.S)
            self.assertEqual(len(rows),3)
            if lane=='v':
                for expression in rows[:2]:self.assertIn('!pipe_u_eff.is_mem',expression)
        for profile in (0,1,2):
            smt=proof.problem(self.sources,profile)
            self.assertIn('(define-fun old_commit',smt)
            self.assertIn('(define-fun new_commit',smt)

    def test_mutants_target_the_tested_contract(self):
        positive=leaf.module(self.sources)
        for mutation in ('stale-alu','stale-shift','wrong-prediction'):
            changed=leaf.module(self.sources,mutation)
            self.assertNotEqual(changed,positive)
        with self.assertRaises(AssertionError):leaf.module(self.sources,'unsupported')

    def test_full_core_plan_and_coverage_unchanged(self):
        def assignment(source,name):
            rows=[n for n in ast.walk(ast.parse(source)) if isinstance(n,ast.Assign)
                  and any(isinstance(t,ast.Name) and t.id==name for t in n.targets)]
            self.assertEqual(len(rows),1)
            return ast.dump(rows[0])
        old,new=prior.derive(),current.derive()
        for name in ('plan','commands','common'):
            self.assertEqual(assignment(old,name),assignment(new,name))
        for marker in ("assert result['probe_runs'] == 4240",'clocks=21190336,agi=18172,ref=24352',
                       "assert started['changes'] == ['rtl/core/core_mem_chain.svh']"):
            self.assertIn(marker,new)

    def test_directed_corners_change_instructions_not_state(self):
        source=(Path(__file__).resolve().parents[2]/'verif/fe_pipe/raw-branch-prime.S').read_text()
        shifted=fixture(source,'shift')
        preserved=fixture(source,'preserve')
        alternating=fixture(source,'alternating')
        self.assertIn('shll $1,%edi\nhot_branch:\n    je branch_taken',shifted)
        self.assertEqual(shifted.count('xorl %esi,%esi\n    jmp hot_u'),2)
        self.assertIn('movl $0,%esi\nhot_branch:\n    je branch_taken',preserved)
        self.assertIn('xorl %ebx,%edi\nhot_branch:\n    jne branch_taken',alternating)
        for text in (shifted,preserved,alternating):
            tail=text.split('hot_load:',1)[1]
            if text==shifted:
                # Re-arm deliberately stale ZF before every loop iteration.
                self.assertEqual(tail.count('xorl %esi,%esi\n    jmp hot_u'),1)
                tail=tail.replace('xorl %esi,%esi\n    jmp hot_u','testl %edi,%edi\n    jmp hot_u')
            self.assertEqual(tail,source.split('hot_load:',1)[1])
        with self.assertRaises(AssertionError):fixture(source,'unsupported')


if __name__=='__main__':unittest.main()
