#!/usr/bin/env python3
"""Recipe guards; behavioral permission coverage is in the actual-include leaf."""
import importlib.util
from pathlib import Path
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('recipe',HERE/'prepare-ifetch-auth-multi.py')
recipe=importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)

class Recipe(unittest.TestCase):
    def setUp(self):
        self.source=(HERE.parents[1]/'rtl/core/core.sv').read_text()

    def test_exact_default_off(self):
        changed=recipe.transform(self.source)
        wrapper='''`ifdef VEN_IFETCH_AUTH_MULTI
  `include "core_ifetch_auth_multi.svh"
`else
'''+recipe.OLD+'\n`endif'
        self.assertEqual(changed.count(wrapper),1)
        self.assertEqual(changed.replace(wrapper,recipe.OLD),self.source)

    def test_fail_closed(self):
        for source in ('',self.source+self.source,recipe.transform(self.source),
                       self.source.replace('if_auth_page_q == flin[31:12]','1\'b1')):
            with self.subTest(source=source[:30]), self.assertRaises(ValueError):
                recipe.transform(source)

if __name__=='__main__':unittest.main()
