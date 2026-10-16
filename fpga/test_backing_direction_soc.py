"""Exact full-PC source/profile admission and negative evidence controls."""
from pathlib import Path
import unittest
from unittest.mock import patch

import build_backing_direction_soc as b

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class Transfer(unittest.TestCase):
    def test_exact_shared_closure_and_aux(self):
        parent=ROOT/'v-result-carry-soc-r1';core=ROOT/'backing-direction-core-r1'
        names=b.load(parent/'build-started.json')['intersecting_rtl_sources']
        self.assertEqual(len(names),102)
        changes=sorted(n for n in names if b.check_delta(n,(parent/'source'/n).read_bytes(),
                                                        (core/'candidate'/n).read_bytes()))
        self.assertEqual(changes,b.CHANGES)
        self.assertEqual(b.sha(parent/'source'/b.previous.AUX),b.previous.AUX_SHA)

    def test_extra_or_incorrect_delta_rejected(self):
        old=(ROOT/'v-result-carry-soc-r1/source'/b.FILE).read_bytes()
        new=(ROOT/'backing-direction-core-r1/candidate'/b.FILE).read_bytes()
        for bad in (old,new+b'\n'):
            with self.assertRaises(AssertionError):b.check_delta(b.FILE,old,bad)
        for name in ('rtl/core/core.sv',b.previous.AUX):
            with self.assertRaises(AssertionError):b.check_delta(name,b'old',b'new')

    def test_exact_uv_fast_posted_profile(self):
        parent=ROOT/'v-result-carry-soc-r1'
        command=b.load(parent/'build-started.json')['command']
        definitions=(parent/'defines.txt').read_text().splitlines()
        self.assertEqual(len(b.check_definitions(command,definitions)),157)
        for bad in (command+['+define+VEN_P54_REGMEM_PRIME'],
                    command+['+define+VEN_UNREVIEWED'],
                    [s for s in command if s!='-GBOARD_WRITE_SLOTS=16']):
            with self.assertRaises(AssertionError):b.check_definitions(bad,definitions)

    def test_closed_evidence_and_zero_v_rejected(self):
        core=ROOT/'backing-direction-core-r1';pins=b.evidence(ROOT,core)
        self.assertIn(str(core/'verify-closed.json'),pins)
        path=ROOT/'backing-direction-mixed-r1/closed.json';original=b.load
        for key in ('memory_v_retirements','wait_held','wait_paired'):
            bad=original(path);bad[key]=0
            with patch.object(b,'load',side_effect=lambda p:bad if p==path else original(p)):
                with self.assertRaises(AssertionError):b.evidence(ROOT,core)


if __name__=='__main__':unittest.main()
