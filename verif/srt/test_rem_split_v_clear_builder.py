import copy
from pathlib import Path
import unittest

import build_rem_split_v_clear_core as build

ROOT=Path('/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS/payload-current-core-r1')


class AdmissionTests(unittest.TestCase):
    def test_real_command_only_adds_split_flag(self):
        old=build.load(ROOT/'build-started.json')['command']
        self.assertEqual(len(build.definitions(old)),152)
        for token in ('+define+VEN_SYS_FASTPATH_RELOC','+define+VEN_FP_SHARED','--assert'):
            changed=[s.replace(token,'') for s in old]
            with self.assertRaises(AssertionError):build.definitions(changed)
        changed=[s+' +define+'+build.srt.FLAG if s.startswith('VL_EXTRA_DEFINES=') else s for s in old]
        with self.assertRaises(AssertionError):build.definitions(changed)

    def test_failing_or_missing_mutant_is_not_admitted(self):
        root=Path('/home/yukidama/external/tmp/ventium-srt-rem-split.pM3Jsjhi/miter-r1')
        evidence=build.load(root/'closed.json')
        expected=[('disabled',0,0),('enabled',0,0),('wrong-rem-port',0,1),('wrong-idle-carry',0,1)]
        build.proof_rows(evidence,expected)
        for index,key,value in ((0,'build_exit',1),(1,'native_exit',1),(2,'native_exit',0),(3,'artifacts',{})):
            wrong=copy.deepcopy(evidence);wrong['rows'][index][key]=value
            with self.assertRaises(AssertionError):build.proof_rows(wrong,expected)


if __name__=='__main__':unittest.main()
