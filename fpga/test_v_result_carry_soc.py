"""Source/profile transfer guards, independent of the pending native PC build."""
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import build_v_result_carry_soc as b

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class Transfer(unittest.TestCase):
    def test_all_shared_inputs_and_aux_preserved(self):
        parent=ROOT/'pipe-wait-aux-soc-r2';core=ROOT/'v-result-carry-core-r1'
        before=json.loads((parent/'build-started.json').read_text())
        names=before['intersecting_rtl_sources'];self.assertEqual(len(names),102)
        actual=sorted(n for n in names if b.check_delta(n,(parent/'source'/n).read_bytes(),
                                                       (core/'candidate'/n).read_bytes()))
        self.assertEqual(actual,b.CHANGES)
        self.assertEqual(b.sha(parent/'source'/b.AUX),b.AUX_SHA)
        with self.assertRaises(AssertionError):b.check_delta(b.AUX,b'old',b'new')

    def test_extra_and_incorrect_delta_rejected(self):
        for name in b.CHANGES:
            before=(ROOT/'pipe-wait-aux-soc-r2/source'/name).read_bytes()
            after=(ROOT/'v-result-carry-core-r1/candidate'/name).read_bytes()
            for wrong in (before,after+b'\n'):
                with self.assertRaises(AssertionError):b.check_delta(name,before,wrong)
        with self.assertRaises(AssertionError):b.check_delta('rtl/core/decode.sv',b'old',b'new')

    def test_exact_profile_and_posted_transport(self):
        parent=ROOT/'pipe-wait-aux-soc-r2'
        command=b.load(parent/'build-started.json')['command']
        definitions=(parent/'defines.txt').read_text().splitlines()
        self.assertEqual(len(b.check_definitions(command,definitions)),157)
        for bad in (command+['+define+VEN_P54_REGMEM_PRIME'],
                    [s for s in command if s!='-GBOARD_WRITE_SLOTS=16'],
                    command+['+define+VEN_NEW_FEATURE']):
            with self.assertRaises(AssertionError):b.check_definitions(bad,definitions)

    def test_native_evidence_and_zero_pair_mutants(self):
        core=ROOT/'v-result-carry-core-r1';pins=b.evidence(ROOT,core)
        self.assertIn(str(ROOT/'v-result-carry-held-r1/result.json'),pins)
        original=b.load
        for name,key in (('system','subject_v_retirements'),('mixed','wait_held'),('mixed','wait_paired')):
            path=ROOT/('v-result-carry-'+name+'-r1/closed.json');bad=original(path);bad[key]=0
            with patch.object(b,'load',side_effect=lambda p:bad if p==path else original(p)):
                with self.assertRaises(AssertionError):b.evidence(ROOT,core)


if __name__=='__main__':unittest.main()
