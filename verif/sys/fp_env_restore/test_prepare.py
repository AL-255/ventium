import os
from pathlib import Path
import unittest

import prepare


class Recipe(unittest.TestCase):
    def test_two_file_scope_and_guards(self):
        root=Path(os.environ['FP_ENV_PARENT'])
        for name in prepare.PARENTS:
            before=(root/name).read_text();after=prepare.transform(before,name)
            self.assertNotEqual(before,after)
            for bad in (before+'\n',after):
                with self.assertRaises(ValueError):prepare.transform(bad,name)
            if name.endswith('core.sv'):
                self.assertEqual(after,before.replace('.cmd_real_mode(real_mode),','.cmd_real_mode(seg_real),'))
            else:
                self.assertIn(prepare.POINTERS,after)
                for value in ('fip','fdp','fcs','fds'):
                    self.assertIn('c_env ? env_load_'+value+' : cmd_'+value,after)
                self.assertEqual(after.count("c_eptr        = 1'b1;"),1)
                self.assertEqual(after.count("c_dptr        = 1'b1;"),1)


if __name__=='__main__':unittest.main()
