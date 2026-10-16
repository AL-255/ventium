"""Exact two-file PC transfer and preservation of existing input repairs."""
import unittest

import build_qualified_pair_credit_soc as build


class Transfer(unittest.TestCase):
    def test_every_shared_source_is_unchanged_or_exact_recipe(self):
        before = build.load(build.PARENT/'build-started.json')
        shared = before['intersecting_rtl_sources']
        self.assertEqual(len(shared), 102)
        changed = []
        for name in shared:
            old, new = (build.PARENT/'source'/name).read_bytes(), (build.CORE/'candidate'/name).read_bytes()
            if build.check_delta(name, old, new): changed.append(name)
            with self.assertRaises(AssertionError): build.check_delta(name, old, new+b'\n')
        self.assertEqual(sorted(changed), build.CHANGES)
        self.assertEqual(len(changed), 2)

    def test_private_host_and_input_binding_survive(self):
        text = build.adapted_prepare()
        compile(text, build.__file__, 'exec')
        for token in ("'sim_qualified_pair_credit_'", 'shutil.copyfile(old_host,host)',
                      "binding_read_wire='kb_fifo_rdreq'", 'sha(source/PS2)==PS2_SHA',
                      'added_defines=[]', 'transfer.check_definitions', 'assert stable(pins)',
                      "qualification='UNQUALIFIED'", 'canonical_gate_passed=False'):
            self.assertIn(token, text)


if __name__ == '__main__':
    unittest.main()
