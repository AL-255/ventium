import ast
import unittest
from unittest.mock import patch

import build_prime_width_ui_soc as build
import run_prime_width_ui_build as run
import test_next_ready_ui_transfer as transfer
import test_next_ready_ui_build as owner


class Compose(transfer.Compose):
    def test_only_exact_controller_delta(self):
        with patch.object(transfer,'build',build):super().test_only_exact_controller_delta()

    def test_identical_qualified_host_and_binding(self):
        with patch.object(transfer,'build',build):super().test_identical_qualified_host_and_binding()

    def test_unchanged_cpu_and_closed_controls(self):
        text=build.prepare_source();ast.parse(text)
        for marker in ("assert changed == [ui.PS2]","processor_rtl_changes=[]",
                       "controls['model']==PARENT_MODEL","controls['no_oom']",
                       "r['parent_ticks']==r['candidate_ticks']",'assert stable(pins)',
                       'source.rglob','cpu.check_definitions','Path(template.__file__)'):
            self.assertIn(marker,text)
        self.assertEqual(build.PARENT.name,'prime-width-soc-r1')


class WaitOwner(owner.WaitOwner):
    def test_only_exact_terminal_owner_can_build(self):
        with patch.object(owner,'run',run):super().test_only_exact_terminal_owner_can_build()

    def test_lifetime_and_build_guards_preserved(self):
        text=run.derive();ast.parse(text)
        for marker in ("assert disposition(initial) == 'wait'","Path('/proc',initial['MainPID']).exists()",
                       'time.monotonic()-started < 3000','free > 5*1024**3',
                       "assert closed['passed'] and closed['error'] is None",
                       "'6486dfa5929e45f78d351a1622f67466'",'build.cpu.base.build(root)',
                       'Verilator 5.046','assert build.stable(pins)','Path(template.__file__)'):
            self.assertIn(marker,text)


if __name__=='__main__':unittest.main()
