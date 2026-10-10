import re
import unittest

import prepare_buffered_integration as b
from prepare_integration import FLAG, HEADER


class BufferedIntegration(unittest.TestCase):
    def setUp(self):
        self.source = ('localparam int IWORDS = 4;\n'
                       'logic [3:0] d_len;\nlogic [3:0] sfetch_short_len_q;\n'
                       '`ifdef '+FLAG+'\n`include "'+HEADER+'"\n`endif\n' +
                       ('`ifdef '+FLAG+'\n`endif\n')*3)
        for raw,_,count in b.REPLACEMENTS:
            self.source += ('    && '+raw+';\n')*count
        self.source += 'wire other = ic_buffered(arbitrary_target);\n'

    def test_exact_replacements_and_old_lines(self):
        result = b.transform(self.source)
        self.assertEqual(result.count('`ifdef '+FLAG),19)
        for raw,new,count in b.REPLACEMENTS:
            self.assertEqual(result.count('    && '+raw+';'),count)
            self.assertEqual(result.count('    && '+new+';'),count)
        self.assertIn('wire other = ic_buffered(arbitrary_target);',result)

    def test_all_nonlookup_guards_and_punctuation_retained(self):
        source=self.source.replace('    && ic_buffered(flin);',
                                   '    && exec_issue_ok && ic_buffered(flin));')
        for old,new in b.changed_lines(source):
            old_skeleton,new_skeleton=old,new
            for raw,factored,_ in b.REPLACEMENTS:
                old_skeleton=old_skeleton.replace(raw,'PREDICATE')
                new_skeleton=new_skeleton.replace(factored,'PREDICATE')
            self.assertEqual(old_skeleton,new_skeleton)

    def test_predicate_inside_multiline_or_group(self):
        source=self.source.replace("    && ic_buffered(flin + 32'd1);",
                                   "                             ic_buffered(flin + 32'd1));")
        result=b.transform(source)
        self.assertIn("                             ic_res_buffered_offset(6'd1));",result)

    def test_default_off_recovers_exact_source(self):
        result=b.transform(self.source).split('\n',1)[1]
        # Only unfold the newly inserted expression-line branches, not the
        # parent's include and three other presence-call branches.
        result=re.sub(r'`ifdef '+FLAG+r'\n([^`]*?)`else\n([^`]*?)`endif\n',
                      lambda m:m[2],result)
        self.assertEqual(result,self.source)

    def test_width_and_window_drift_refused(self):
        for old,new in (('IWORDS = 4','IWORDS = 8'),('[3:0] d_len','[4:0] d_len'),
                        ('[3:0] sfetch_short_len_q','[4:0] sfetch_short_len_q')):
            with self.subTest(old=old),self.assertRaises(ValueError):
                b.transform(self.source.replace(old,new))

    def test_partial_or_double_integration_refused(self):
        for source in (self.source.replace(HEADER,'missing.svh'),
                       self.source+'`ifdef '+FLAG+'\n`endif\n',
                       b.transform(self.source)):
            with self.subTest(source=source),self.assertRaises(ValueError):b.transform(source)

    def test_missing_or_unreviewed_call_refused(self):
        for source in (self.source.replace('ic_buffered(flin);','unknown;',1),
                       self.source+'    && ic_buffered(flin);\n',
                       self.source+'    && ic_buffered(arbitrary_target);\n'):
            with self.subTest(source=source),self.assertRaises(ValueError):b.transform(source)


if __name__ == '__main__':unittest.main()
