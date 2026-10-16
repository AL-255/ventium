import ast
import unittest
from unittest.mock import patch

import build_sfetch_interior_ui_soc as build
import test_next_ready_ui_transfer as previous


class Compose(previous.Compose):
    def test_only_exact_controller_delta(self):
        with patch.object(previous,'build',build):
            super().test_only_exact_controller_delta()

    def test_identical_qualified_host_and_binding(self):
        with patch.object(previous,'build',build):
            super().test_identical_qualified_host_and_binding()

    def test_cpu_and_closed_regression_guards(self):
        text=build.prepare_source();ast.parse(text)
        for marker in ("assert changed == [ui.PS2]", "processor_rtl_changes=[]",
                       "controls['model']==PARENT_MODEL", "controls['no_oom']",
                       "r['parent_ticks']==r['candidate_ticks']", 'assert stable(pins)',
                       'source.rglob', 'cpu.check_definitions'):
            self.assertIn(marker,text)
        self.assertEqual(build.PARENT.name,'sfetch-interior-soc-r1')


if __name__=='__main__':unittest.main()
