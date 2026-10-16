"""Exact shared-source transfer, native replay and retained input guards."""
import unittest

import build_parallel_write_soc as build


class Transfer(unittest.TestCase):
    def test_every_shared_source_is_unchanged_or_exact_recipe(self):
        shared = build.load(build.PARENT/'build-started.json')['intersecting_rtl_sources']
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
        for token in ("'sim_parallel_write_'", 'shutil.copyfile(old_host,host)',
                      "binding_read_wire='kb_fifo_rdreq'", 'sha(source/PS2)==PS2_SHA',
                      'added_defines=[]', 'transfer.check_definitions', 'assert stable(pins)',
                      "qualification='UNQUALIFIED'", 'canonical_gate_passed=False'):
            self.assertIn(token, text)

    def test_native_same_input_checks_are_not_waived(self):
        text = build.adapted_evidence()
        compile(text, build.__file__, 'exec')
        for token in ('parallel-write-replay-r1', 'parallel-write-func-r1/audit.json',
                      "len(closed['rows']) == 108", "witness['actual_wait']",
                      "witness['group_closed']", 'read_trace(str(old)).records =='):
            self.assertIn(token, text)
        self.assertNotIn('qualified-pair-credit-', text)

    def test_only_documented_historical_source_may_be_rebound(self):
        name, (old, archive) = next(iter(build.HISTORICAL_SOURCES.items()))
        pins = {name: old, 'unchanged-file': 'identity'}
        self.assertEqual(build.historical(pins),
                         {str(archive): old, name: build.sha(name), 'unchanged-file': 'identity'})
        self.assertEqual(pins[name], old)
        self.assertEqual(build.historical({name: 'unqualified'}), {name: 'unqualified'})


if __name__ == '__main__': unittest.main()
