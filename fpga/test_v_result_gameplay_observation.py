import ast
import unittest

import audit_v_result_gameplay_observation as audit


class Observation(unittest.TestCase):
    def test_counter_and_native_guards_retained(self):
        text = audit.derive([12,13], [7,8], ['Stone corridor, weapon and HUD',
                                         'Shotgun firing with impact, weapon and HUD'])
        ast.parse(text)
        for token in ('window.cpi.samples(lines,1200065247,1300065247)',
                      "delta['clocks']==100000000", "delta['u']>0 and delta['v']>0",
                      'observed_cycles[:13]', 'range(4,14)', 'sample_indices=[12, 13]',
                      'assert actual==index', 'pixels(ppm)==pixels(png)',
                      'window.cpi.validate_profile(delta,is_delta=True)',
                      "os.sched_getaffinity(native['pid'])=={14}",
                      "command==native['argv']==inputs['command'][3:]",
                      "not inputs['snapshots']", "closed['native_exit']==0",
                      'whole_timedemo=False', 'physical_fpga=False',
                      "output.open('x')", 'Path(adapter.__file__)'):
            self.assertIn(token, text)
        self.assertNotIn('==48146083', text)
        self.assertNotIn("v-result-carry-gameplay-window-oct16-r1.json", text)

    def test_bad_intervals_and_missing_review_rejected(self):
        for samples, frames, reviews in (
            ([10,11],[5,6],['Game view one','Game view two']),
            ([12,12],[7,8],['Game view one','Game view two']),
            ([12,13],[8,7],['Game view one','Game view two']),
            ([12,13],[7,8],['','Game view two']),
        ):
            with self.subTest(samples=samples,frames=frames,reviews=reviews):
                with self.assertRaises(AssertionError): audit.derive(samples,frames,reviews)


if __name__ == '__main__': unittest.main()
