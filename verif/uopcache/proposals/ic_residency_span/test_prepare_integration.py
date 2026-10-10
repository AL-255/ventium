import re
import unittest

import prepare_integration as p


class IntegrationGuards(unittest.TestCase):
    def setUp(self):
        self.source = """logic [3:0] d_len;
wire [5:0] fp_pipe_decode_win_last = cond ? 6'd6 : 6'd5;
  // END IC FRONT SPAN
always_comb begin
    pipe_bytes_ok = guard && ic_present(flin) &&
        (early || ic_present(flin + {26'd0,fp_pipe_decode_win_last})) &&
        (other || ic_present(flin + {28'd0,u_d.len} - 32'd1));
    pf_miss_fa = !ic_present(flin) ? flin :
        !ic_present(flin + {26'd0,fp_pipe_decode_win_last}) ?
          flin + {26'd0,fp_pipe_decode_win_last} : flin + {28'd0,u_d.len} - 32'd1;
    v_bytes_ok = guard && handoff && ic_present(flin + {28'd0,u_d.len}) &&
        ic_present(flin + {28'd0,u_d.len} + {28'd0,v_d.len} - 32'd1);
end
"""

    def test_only_reviewed_bodies(self):
        result = p.replacement_bodies(self.source)
        self.assertEqual(set(result),set(p.CALLERS))
        for name,body in result.items():
            self.assertNotIn('ic_present(',body)
            self.assertEqual(body.count(';'),1)
        self.assertIn('guard && handoff &&',result['v_bytes_ok'])
        self.assertIn("flin + {28'd0,u_d.len} - 32'd1",result['pf_miss_fa'])

    def test_original_fallback_bodies_are_exact(self):
        result = p.transform(self.source)
        for name,body in p.assignments(self.source).items():
            matches = re.findall(r'`else\s*('+name+r'\s*=.*?;)\s*`endif',result,re.S)
            self.assertEqual(matches,[body])
        self.assertEqual(result.count('`ifdef '+p.FLAG),4)
        self.assertEqual(result.count('`include "'+p.HEADER+'"'),1)

    def test_double_application_refused(self):
        with self.assertRaisesRegex(ValueError,'already integrated'):
            p.transform(p.transform(self.source))

    def test_bounds_drift_refused(self):
        for old,new in [('logic [3:0] d_len','logic [4:0] d_len'),("6'd6 : 6'd5","6'd33 : 6'd5")]:
            with self.subTest(old=old),self.assertRaises(ValueError):
                p.transform(self.source.replace(old,new))

    def test_missing_duplicate_or_unreviewed_caller_refused(self):
        for source in (self.source.replace('pipe_bytes_ok =','wrong ='),
                       self.source+'\npipe_bytes_ok = ic_present(flin);\n',
                       self.source.replace('guard && handoff &&','guard && ic_present(arbitrary_target) &&')):
            with self.subTest(source=source),self.assertRaises(ValueError): p.transform(source)

    def test_count_and_marker_drift_refused(self):
        for source in (self.source.replace('ic_present(flin) ?','replacement ?'),
                       self.source.replace('// END IC FRONT SPAN','// unknown boundary')):
            with self.subTest(source=source),self.assertRaises(ValueError): p.transform(source)


if __name__ == '__main__': unittest.main()
