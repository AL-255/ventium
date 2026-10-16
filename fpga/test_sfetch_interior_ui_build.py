import ast
import unittest
from unittest.mock import patch

import run_sfetch_interior_ui_build as run
import test_next_ready_ui_build as previous


class WaitOwner(previous.WaitOwner):
    def test_only_exact_terminal_owner_can_build(self):
        with patch.object(previous,'run',run):
            super().test_only_exact_terminal_owner_can_build()

    def test_lifetime_and_build_guards_preserved(self):
        text=run.derive();ast.parse(text)
        for marker in ("assert disposition(initial) == 'wait'", "Path('/proc',initial['MainPID']).exists()",
                       'time.monotonic()-started < 3000', 'free > 5*1024**3',
                       "assert closed['passed'] and closed['error'] is None",
                       "'ad8028d56f994bd8ac7a081b4ded17c9'", 'build.cpu.base.build(root)',
                       'Verilator 5.046', 'assert build.stable(pins)'):
            self.assertIn(marker,text)


if __name__=='__main__':unittest.main()
