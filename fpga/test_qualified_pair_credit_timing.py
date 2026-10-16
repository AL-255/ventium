"""Preserve resource guards and reject implicit historical-source substitutions."""
import ast
from pathlib import Path
import unittest
from unittest.mock import patch

import prepare_qualified_pair_credit_timing as timing


class Timing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={}
        for name,digest in timing.TEMPLATES.items():
            path=timing.ROOT/name
            assert timing.sha(path)==digest
            cls.original[name]=path.read_text()
        cls.output=timing.derive(cls.original)

    def test_resource_lifecycle_disk_admission_and_tcl_exact(self):
        for phase,folder in (('synthesis',timing.SYNTH),('clock',timing.CLOCK)):
            old=self.original['raw-prime-storage-'+phase+'-r1/run.py']
            new=self.output[folder+'/run.py']
            mark='owner = None\n'
            self.assertEqual(new[new.index(mark):],old[old.index(mark):])
            a,b='host = available()\n',"(root/'once').mkdir()"
            self.assertEqual(new[new.index(a):new.index(b)],old[old.index(a):old.index(b)])
            tcl='launch_checked.tcl' if phase=='synthesis' else 'audit.tcl'
            self.assertEqual(self.output[folder+'/'+tcl],self.original['raw-prime-storage-'+phase+'-r1/'+tcl])

    def test_exact_raw_parent_two_deltas_and_no_acceptance(self):
        for name,text in self.output.items():
            if name.endswith('.py'):
                ast.parse(text)
                self.assertNotIn('sfetch-boundary-',text)
        source=self.output[timing.SYNTH+'/audit_closed.py']
        self.assertIn('raw-prime-storage-fpga-r1',source)
        self.assertIn(timing.evidence.export.PARENT,source)
        changes=[ast.literal_eval(n.value) for n in ast.parse(source).body if isinstance(n,ast.Assign)
                 and any(isinstance(t,ast.Name) and t.id=='expected_changes' for t in n.targets)]
        self.assertEqual(len(changes),1)
        self.assertEqual(sorted(changes[0]),timing.evidence.export.CHANGES)
        clock=self.output[timing.CLOCK+'/run.py']
        self.assertIn(timing.PARENT_DCP,clock)
        self.assertIn('hardware_acceptance=False',clock)
        self.assertIn('parent_worst - (-3.269)',self.output[timing.CLOCK+'/audit_closed.py'])

    def test_current_gate_is_explicitly_red_and_baseline_current(self):
        for folder in (timing.SYNTH,timing.CLOCK):
            source=self.output[folder+'/run.py']
            self.assertIn('pins=evidence.check(source)',source)
            self.assertIn('nine cycle-band failures',source)
            self.assertIn('baseline_gameplay_ipc=0.497040387',source)
            self.assertIn('baseline_window=[1100065247,2100065247]',source)
            self.assertNotIn('baseline_gameplay_ipc=0.50229051',source)

    def test_known_historical_bytes_and_current_files_both_pinned(self):
        evidence=timing.evidence
        for name,(digest,archive) in evidence.ALIASES.items():
            result=evidence.historical({name:digest})
            self.assertEqual(result[str(archive)],digest)
            self.assertEqual(result[name],evidence.sha(name))

    def test_wrong_digest_is_not_silently_rebound(self):
        evidence=timing.evidence
        for name in evidence.ALIASES:
            self.assertEqual(evidence.historical({name:'0'*64}),{name:'0'*64})
        self.assertEqual(evidence.historical({'/unrelated/source':'1'*64}),{'/unrelated/source':'1'*64})

    def test_changed_archive_is_rejected(self):
        evidence=timing.evidence
        name,(digest,archive)=next(iter(evidence.ALIASES.items()))
        with patch.object(evidence,'sha',return_value='0'*64):
            with self.assertRaises(AssertionError):evidence.historical({name:digest})


if __name__=='__main__':unittest.main()
