"""Reject bad completion witnesses without changing the guest or comparator."""
import copy
from pathlib import Path
import unittest

import run_early_bus_physical as check

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/early-bus-physical-r1')


class Witnesses(unittest.TestCase):
    def test_real_mode_witness_mutants(self):
        trace=ROOT/'real-int/candidate-lat0-cycle-func.vtrace'
        rows=check.tracefmt.read_trace(str(trace)).records
        check.grade('real-int',rows,trace.with_suffix('.json'))
        for key in ('eax','edi','esi','ebx','esp','cs'):
            bad=copy.deepcopy(rows); bad[-1][key]='0x00000000'
            with self.assertRaises(AssertionError): check.grade('real-int',bad,trace.with_suffix('.json'))

    def test_smm_metadata_witness_mutants(self):
        trace=ROOT/'psmmmeta/candidate-lat0-cycle-func.vtrace'
        rows=check.tracefmt.read_trace(str(trace)).records
        check.grade('psmmmeta',rows,trace.with_suffix('.json'))
        for key in ('eax','edi','esi','ebx','ebp','ecx','edx'):
            bad=list(rows); bad[-1]=dict(rows[-1],**{key:'0x00000000'})
            with self.assertRaises(AssertionError): check.grade('psmmmeta',bad,trace.with_suffix('.json'))
        with self.assertRaises(AssertionError): check.grade('psmmmeta',[rows[-1]],trace.with_suffix('.json'))


if __name__=='__main__': unittest.main()
