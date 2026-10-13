import ast
from pathlib import Path
import unittest

import prepare_lmsw_doom as recipe


class Recipe(unittest.TestCase):
    def test_scope_and_unchanged_guards(self):
        source=Path(recipe.__file__).with_name('run_endpoint_map_doom_smoke.py').read_text()
        changed=recipe.transform(source)
        ast.parse(changed)
        self.assertIn("pc=timing.ROOT/'lmsw-soc-r1'",changed)
        self.assertEqual(changed.count(recipe.MODEL),2)
        self.assertEqual(changed.count('50000000'),2)
        for guard in ('child_reaped', "'--ven-fault-ring-events','8'", 'native.stable(pins)',
                      'guest_executable_and_wad_unchanged', 'resource.setrlimit', "observed['affinity']==[12]"):
            self.assertIn(guard,changed)
        for forbidden in ('--snapshot-in','--snapshot-out','--break-eip','--step'):
            self.assertNotIn(forbidden,changed)

    def test_drift_and_reapplication(self):
        source=Path(recipe.__file__).with_name('run_endpoint_map_doom_smoke.py').read_text()
        for wrong in (source+'\n',recipe.transform(source)):
            with self.assertRaises(ValueError): recipe.transform(wrong)


if __name__=='__main__': unittest.main()
