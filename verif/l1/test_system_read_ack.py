"""Source-drift and preservation tests; native ACK miter is a separate gate."""
import hashlib
from pathlib import Path
import re
import unittest

import prepare_system_read_ack as recipe
import run_system_read_ack_leaf as runner

PARENT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/raw-prime-storage-core-r1/candidate/rtl/core')


class SystemReadAck(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources = {n:(PARENT/n).read_text() for n in recipe.PARENTS}
        cls.changed = {n:recipe.transform(s,n) for n,s in cls.sources.items()}
        cls.bus = (PARENT/'core_bus_driver.svh').read_text()

    def test_exact_parent_and_reapplication_rejected(self):
        for n,s in self.sources.items():
            with self.assertRaises(ValueError): recipe.transform(s+'\n',n)
            with self.assertRaises(ValueError): recipe.transform(self.changed[n],n)

    def test_only_read_tokens_change_in_case_headers(self):
        for n in (*recipe.OWNERS,'core_gpr_wb.svh'):
            self.assertEqual(self.changed[n].replace('mem_read_ack','mem_ack'),self.sources[n])
            states=recipe.OWNERS.get(n,recipe.GPR_STATES)
            for state in states:
                self.assertEqual(recipe.arm(self.changed[n],state),
                    recipe.arm(self.sources[n],state).replace('mem_ack','mem_read_ack'))

    def test_all_mixed_and_write_owners_unchanged(self):
        for n,states in {'core_tss_priv.svh':['S_LTR'],
                         'core_int_deliver.svh':['S_INT_PUSH'],
                         'core_tsw.svh':['S_TSW_BUSY','S_TSW_SAVE'],
                         'core_seg_ljmp.svh':['S_LCALL','S_SGDT'],
                         'core_rmint.svh':['S_RMINT_PUSH']}.items():
            for state in states:
                self.assertEqual(recipe.arm(self.sources[n],state),recipe.arm(self.changed[n],state))

    def test_walk_body_preserved_and_writes_keep_general_ack(self):
        changed=self.changed['core_walk.svh']
        for label in ("3'd1",'default'):
            self.assertIn(label+': if (mem_ack) begin',changed)
        for label in ("3'd0","3'd2"):
            self.assertIn(label+': if (mem_read_ack) begin',changed)
        inverse=re.sub(r': if \(mem_(?:read_)?ack\) begin',': begin',changed)
        inverse=inverse.replace('        S_WALK: begin\n','        S_WALK: begin\n          if (mem_ack) begin\n')
        inverse=inverse.replace('            endcase\n        end','            endcase\n          end\n        end')
        self.assertEqual(inverse,self.sources['core_walk.svh'])

    def test_core_only_changes_declared_mirrors_and_witness(self):
        core=self.changed['core.sv']
        start=core.index('`ifndef SYNTHESIS\n  // Direction is independently established')
        stop=core.index('`endif\n',start)+len('`endif\n')
        core=core[:start]+core[stop:]
        for alias in recipe.ALIASES:
            new=recipe.assignment(core,alias)
            core=recipe.once(core,new,recipe.assignment(self.sources['core.sv'],alias))
        core=recipe.once(core,'((state == S_IRET) && mem_read_ack && (int_step == 4\'d8)',
                         '((state == S_IRET) && mem_ack && (int_step == 4\'d8)')
        start=core.index('    if (state==S_WALK) begin\n      unique case (walk_step)')
        stop=core.index('\n  // TLB CR3 flush',start)
        block=core[start:stop]
        inverse=re.sub(r': if \(mem_(?:read_)?ack\) begin',': begin',block)
        inverse=inverse.replace('if (state==S_WALK)','if (state==S_WALK && mem_ack)')
        self.assertEqual(core[:start]+inverse+core[stop:],self.sources['core.sv'])

    def test_bus_direction_has_exact_20_read_owners(self):
        proof=recipe.audit_bus(self.bus)
        self.assertEqual(len(set(proof['read_states'])),20)
        self.assertEqual(proof['walk_read_phases'],[0,2])
        with self.assertRaises(ValueError): recipe.audit_bus(self.bus.replace("bd_we =1'b0", "bd_we =1'b1",1))

    def test_native_fixture_and_lifecycle_pinned(self):
        template=(Path(__file__).with_name('system_read_ack_leaf.svh')).read_text()
        fixture=runner.fixture(self.sources,self.bus,template)
        self.assertNotIn('\nCONSUMERS\n',fixture)
        self.assertEqual(len(re.findall(r'^      \d+: selected_ack=',fixture,re.M)),30)
        self.assertIn('samples==61440',fixture)
        self.assertEqual(runner.lifecycle.sha(runner.lifecycle.__file__),runner.LIFECYCLE_SHA)
        for mode in range(1,5): self.assertIn('mutant=='+str(mode),fixture)

    def test_multifile_builder_retains_full_admission(self):
        import build_system_read_ack_core as builder
        source=builder.adapted_main()
        self.assertEqual(len(builder.CHANGES),9)
        for required in ('pass_fds=(9,)', 'len(files) == 195', '== 153',
                         'VEN_X87_MF_STRICT', 'VL_J=32', 'native.build(root)',
                         'CHANGES', 'tb_system_read_ack_', 'old[\'pins\']'):
            self.assertIn(required,source)

    def test_system_runner_keeps_native_supervision(self):
        import run_system_read_ack_core as runner
        supervisor=runner.observed_supervisor()
        self.assertTrue(callable(supervisor))
        self.assertEqual(len(runner.CASES),len(runner.CPUS))
        self.assertEqual(len(set(runner.CPUS)),len(runner.CPUS))
        self.assertFalse({10,11,14}&set(runner.CPUS))


if __name__=='__main__': unittest.main()
