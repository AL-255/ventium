import inspect
import unittest
import build_system_read_ack_soc as build


class Transfer(unittest.TestCase):
    def test_exact_nine_deltas(self):
        self.assertEqual(len(build.CHANGES),9)
        for name in build.CHANGES:
            old=(build.PARENT/'source'/name).read_bytes()
            new=(build.CORE/'candidate'/name).read_bytes()
            self.assertTrue(build.check_delta(name,old,new))
            with self.assertRaises(AssertionError):build.check_delta(name,old,new+b'\n')
        self.assertFalse(build.check_delta('rtl/mem/ven_l1d.sv',b'same',b'same'))
        with self.assertRaises(AssertionError):build.check_delta('rtl/mem/ven_l1d.sv',b'old',b'new')

    def test_all_shared_sources_match_or_are_exact_delta(self):
        old=build.load(build.PARENT/'build-started.json')
        shared=old['intersecting_rtl_sources']
        self.assertEqual(len(shared),102)
        self.assertEqual(sorted(n for n in shared if build.check_delta(n,
            (build.PARENT/'source'/n).read_bytes(),(build.CORE/'candidate'/n).read_bytes())),build.CHANGES)

    def test_lineage_and_host_are_preserved(self):
        source=inspect.getsource(build.prepare)
        for text in ('shutil.copyfile(old_host,host)','transfer.check_definitions',
                     "binding_read_wire='kb_fifo_rdreq'",'inherited_cycle_cost=',
                     'added_defines=[]','sha(source/PS2)==PS2_SHA','assert stable(pins)'):
            self.assertIn(text,source)
        self.assertIn('return transfer.base.build(root)',inspect.getsource(build.main))


if __name__=='__main__':unittest.main()
