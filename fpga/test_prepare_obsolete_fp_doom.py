import ast
from pathlib import Path
import unittest

import prepare_obsolete_fp_doom as recipe


class Recipe(unittest.TestCase):
    def test_scope_guards_and_drift(self):
        source=Path(recipe.__file__).with_name('run_endpoint_map_doom_smoke.py').read_text()
        text=recipe.transform(source);ast.parse(text)
        self.assertEqual(text.count(recipe.MODEL),2)
        self.assertEqual(text.count('50000000'),2)
        self.assertIn("pc=timing.ROOT/'obsolete-fp-soc-r1'",text)
        for guard in ('child_reaped',"'--ven-fault-ring-events','8'",'native.stable(pins)',
                      'guest_executable_and_wad_unchanged','resource.setrlimit',"observed['affinity']==[12]"):
            self.assertIn(guard,text)
        for forbidden in ('--snapshot-in','--snapshot-out','--break-eip','--step'):
            self.assertNotIn(forbidden,text)
        for wrong in (source+'\n',text):
            with self.assertRaises(ValueError):recipe.transform(wrong)


if __name__=='__main__':unittest.main()
