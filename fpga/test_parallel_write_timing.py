"""Keep matched timing, native lifecycle and disk/memory admission exact."""
import ast
import unittest
from unittest.mock import patch

import prepare_parallel_write_timing as timing


class Timing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        for name, digest in timing.TEMPLATES.items():
            path = timing.ROOT/name
            assert timing.sha(path) == digest
            cls.original[name] = path.read_text()
        cls.output = timing.derive(cls.original)

    def test_resource_lifecycle_disk_admission_and_tcl_exact(self):
        for phase, folder in (('synthesis',timing.SYNTH), ('clock',timing.CLOCK)):
            old, new = self.original['raw-prime-storage-'+phase+'-r1/run.py'], self.output[folder+'/run.py']
            mark = 'owner = None\n'
            self.assertEqual(new[new.index(mark):], old[old.index(mark):])
            a, b = 'host = available()\n', "(root/'once').mkdir()"
            self.assertEqual(new[new.index(a):new.index(b)], old[old.index(a):old.index(b)])
            tcl = 'launch_checked.tcl' if phase == 'synthesis' else 'audit.tcl'
            self.assertEqual(self.output[folder+'/'+tcl], self.original['raw-prime-storage-'+phase+'-r1/'+tcl])

    def test_exact_raw_parent_two_deltas_and_no_acceptance(self):
        for name, text in self.output.items():
            if name.endswith('.py'):
                ast.parse(text)
                self.assertNotIn('sfetch-boundary-', text)
        source = self.output[timing.SYNTH+'/audit_closed.py']
        self.assertIn('raw-prime-storage-fpga-r1', source)
        self.assertIn(timing.evidence.export.PARENT, source)
        changes = [ast.literal_eval(n.value) for n in ast.parse(source).body if isinstance(n,ast.Assign)
                   and any(isinstance(t,ast.Name) and t.id == 'expected_changes' for t in n.targets)]
        self.assertEqual(len(changes), 1)
        self.assertEqual(sorted(changes[0]), timing.evidence.export.CHANGES)
        self.assertIn(timing.PARENT_DCP, self.output[timing.CLOCK+'/run.py'])
        self.assertIn('parent_worst - (-3.269)', self.output[timing.CLOCK+'/audit_closed.py'])

    def test_canonical_failure_not_relabelled(self):
        for folder in (timing.SYNTH, timing.CLOCK):
            source = self.output[folder+'/run.py']
            self.assertIn('pins=evidence.check(source)', source)
            self.assertIn('7/108 functional, nine failed cycle bands', source)
            self.assertIn('baseline_gameplay_ipc=0.497040387', source)
            self.assertIn('baseline_window=[1100065247,2100065247]', source)
            self.assertIn('hardware_acceptance=False', source)
            self.assertNotIn('functional-green', source)

    def test_historical_identity_fail_closed(self):
        native = timing.evidence.native
        name, (digest, archive) = next(iter(native.HISTORICAL_SOURCES.items()))
        mapped = native.historical({name:digest})
        self.assertEqual(mapped[str(archive)], digest)
        self.assertEqual(mapped[name], native.sha(name))
        self.assertEqual(native.historical({name:'unknown'}), {name:'unknown'})
        with patch.object(native, 'sha', return_value='0'*64):
            with self.assertRaises(AssertionError): native.historical({name:digest})


if __name__ == '__main__': unittest.main()
