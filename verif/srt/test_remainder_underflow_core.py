import hashlib
import os
from pathlib import Path
import unittest
import prepare_remainder_underflow_core as recipe
import run_remainder_underflow_checks as checks


class Rebase(unittest.TestCase):
    def test_adapter_identity_only(self):
        parent = Path(os.environ['SRT_UNDERFLOW_CORE_PARENT']).parent
        for mode in checks.SOURCES:
            source,text,changes = checks.derive(mode,parent)
            for old,new in reversed(changes): text = recipe.leaf.once(text,new,old)
            self.assertEqual(text,source.read_text())

    def test_exact_scope(self):
        parent = Path(os.environ['SRT_UNDERFLOW_CORE_PARENT'])
        for name in recipe.PARENTS:
            before = (parent/name).read_text(); after = recipe.transform(before,name)
            with self.assertRaises(ValueError): recipe.transform(after,name)
            with self.assertRaises(ValueError): recipe.transform(before+'\n',name)
            if name == recipe.CORE:
                extra = "    // Legacy status integration is unchanged by the shared-FPU experiment.\n    .rem_underflow_mask(1'b1),\n"
                self.assertEqual(after.replace(extra,''),before)
                self.assertNotIn('u_fetch_metadata',after)
            else:
                self.assertEqual(after,recipe.leaf.transform(before,name))
                self.assertEqual(hashlib.sha256(before.encode()).hexdigest(),recipe.leaf.PARENTS[name])


if __name__ == '__main__': unittest.main()
