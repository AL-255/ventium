import itertools
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import prepare_v_owner_read_clear as patch
import run_v_owner_read_clear as run

CORE=Path('/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS/payload-current-core-r1/candidate/rtl/core/core.sv')


class ClearTests(unittest.TestCase):
    def test_exact_scope_and_rejection(self):
        old=CORE.read_text(); new=patch.transform(old)
        self.assertEqual(new.replace(patch.NEW,patch.OLD).replace(patch.WITNESS,patch.ANCHOR),old)
        for wrong in (old+'\n',new):
            with self.assertRaisesRegex(ValueError,'drift'):
                patch.transform(wrong)

    def test_abstract_binary_consumer(self):
        # All predicate combinations, conditional on the existing read-owner
        # invariant and read-specific ACK equality. Not an inductive core proof.
        count=0
        for owned,active,we,spipe,abort,walk,ack,readack,capture,prime,terminal,fault in itertools.product((False,True),repeat=12):
            if owned and (not active or we): continue
            if active and not we and spipe and readack!=ack: continue
            guard=active and spipe and not abort and not walk
            def nxt(done):
                return False if fault else (True if capture else (False if done or prime or terminal else owned))
            self.assertEqual(nxt(guard and ack),nxt(guard and readack)); count+=1
        self.assertGreater(count,1000)

    def test_native_fixture_keeps_owner_and_mutation_checks(self):
        source=CORE.read_text()
        variants=[run.fixture(source,m) for m in (None,'raw-fragment-ack','missing-read-ack','lost-fault-clear')]
        self.assertEqual(len(set(variants)),4)
        for text in variants:
            self.assertIn('V-CLEAR-STATE-MISMATCH',text)
            self.assertIn('PAIR-RESPONSE owner invariant',text)
            self.assertIn('i<4096',text); self.assertIn('i<65536',text)

    def test_actual_preprocessor_preserves_other_profiles(self):
        scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertEqual(Path(os.environ['TMPDIR']).resolve(),scratch)
        with tempfile.TemporaryDirectory(prefix='v-clear-guard-',dir=scratch) as temp:
            path=Path(temp)/'guard.sv'; output=Path(temp)/'expanded.sv'
            path.write_text(patch.NEW)
            for flags,target in (([],False),(['VEN_RAW_V_READ_PRIME'],True),
                    (['VEN_RAW_V_READ_PRIME','VEN_P54_DUAL_LOAD_PRIME'],False),
                    (['VEN_RAW_V_READ_PRIME','VEN_P54_DUAL_LOAD_PRIME','VEN_P54_REGMEM_PRIME'],False)):
                result=subprocess.run(['iverilog','-g2012','-E',*('-D'+f for f in flags),
                    '-o',str(output),str(path)],capture_output=True,text=True,timeout=5)
                self.assertEqual(result.returncode,0,result.stderr)
                expected=patch.OLD.replace('mem_ack','mem_read_ack') if target else patch.OLD
                self.assertEqual(output.read_text().split(),expected.split())


if __name__=='__main__':unittest.main()
