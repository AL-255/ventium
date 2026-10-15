"""A frozen processor input cannot silently bless arbitrary changed tools."""
from pathlib import Path
import unittest

import build_fetch_fragment_core as transfer
import run_fetch_fragment_checks as checks


class Checks(unittest.TestCase):
    def test_only_qualified_tool_pin_changes(self):
        before={transfer.WORKER:transfer.cache_recipe.preexit.PARENT,'unrelated':'untouched'}
        after=transfer.promote_worker_pin(before,Path(transfer.WORKER).read_text())
        self.assertEqual(after,{transfer.WORKER:transfer.WORKER_NEW,'unrelated':'untouched'})
        self.assertEqual(before[transfer.WORKER],transfer.cache_recipe.preexit.PARENT)

    def test_refuse_tool_or_predecessor_drift(self):
        text=Path(transfer.WORKER).read_text()
        for pins,current in (({},text),({transfer.WORKER:transfer.WORKER_NEW},text),
            ({transfer.WORKER:transfer.cache_recipe.preexit.PARENT},text+'\n')):
            with self.assertRaises(ValueError):
                transfer.promote_worker_pin(pins,current)

    def test_check_adapters_only_change_explicit_bindings(self):
        for mode in ('checks','replay','system'):
            original,_=checks.base.derive(mode)
            changed,edits=checks.derive(mode)
            for before,after in reversed(edits):
                self.assertEqual(changed.count(after),1)
                changed=changed.replace(after,before)
            self.assertEqual(changed,original)


if __name__=='__main__': unittest.main()
