"""Bound the adapter delta and the indirect-fault fixture transformation."""
import unittest
import run_load_read_ack_core as run
from run_load_read_ack_faults import far_fixture, REPO


class CorpusTests(unittest.TestCase):
    def test_fp_only_profile_changes(self):
        source = run.corpus.SOURCES['fp'].read_text()
        old = run.corpus.base.adapt(source,'fp')
        new = run.adapt(source,'fp')
        self.assertEqual(new.replace('added = set()', "added = {'"+run.corpus.base.FLAG+"'}"),old)
        compile(new,'fp','exec')

    def test_integer_preserves_every_comparison(self):
        source = run.corpus.SOURCES['integer'].read_text()
        old = run.corpus.base.adapt(source,'integer')
        new = run.adapt(source,'integer')
        for line in old.splitlines():
            if 'flag =' not in line and 'assert flag not' not in line and '| {flag}' not in line:
                self.assertIn(line,new)
        self.assertIn("assert profiles['candidate'] == profiles['control']",new)
        self.assertIn("assert cycle_records[latency, 'control'] == cycle_records[latency, 'candidate']",new)
        compile(new,'integer','exec')

    def test_canonical_complete_original_corpus(self):
        source = run.Path(run.canonical.__file__).read_text()
        new = run.adapt(source,'canonical')
        self.assertTrue(new.endswith(source.replace('len(profiles[0])==150','len(profiles[0])==152')))
        with self.assertRaises(ValueError): run.adapt(source.replace('len(profiles[0])==150','False'),'canonical')
        compile(new,'canonical','exec')

    def test_indirect_faults_keep_original_cold_setup_and_stack_witness(self):
        source = (REPO/'verif/sys/tests/pcallsel/pcallsel.S').read_text()
        for kind,modrm in (('call','0x1d'),('jump','0x2d')):
            for width,selector in ((16,'0x4a2'),(32,'0x4a4')):
                new=far_fixture(source,kind,width)
                self.assertIn('    .byte 0xff, '+modrm+'\n    .long 0x04a0\n',new)
                self.assertIn('movw $0x0f00, '+selector,new)
                self.assertEqual(new.split('    /* THE FINDING:')[0], source.split('    /* THE FINDING:')[0])
                self.assertIn('movl    $0x0CA10000, %eax',new)
                self.assertIn('movl (%esp), %esi\n    movl 4(%esp), %edi',new)
                self.assertEqual(new.count('load_ack_target:\n    .byte 0x66\n'),width==16)
        with self.assertRaises(AssertionError): far_fixture(source.replace('    .byte   0x9A',''), 'call',32)


if __name__=='__main__': unittest.main()
