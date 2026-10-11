"""Build-command relocation must not change mode flags or reuse model headers."""
from pathlib import Path
import unittest

from build_mc_branch_residency_core import relocate


class Relocation(unittest.TestCase):
    def test_only_owned_paths_move(self):
        parent, root = Path('/external/prior/core'), Path('/external/new/core')
        oldhost, host = parent/'tb_prior.cpp', root/'tb_new.cpp'
        command = ['make', 'RTL_DIR='+str(parent/'candidate/rtl'),
                   'OBJDIR='+str(parent/'obj'), 'VL_J=32',
                   'VL_EXTRA_DEFINES=+define+VEN_FE_PIPE --assert',
                   'CPP_SRCS='+str(oldhost)+' /repo/memmodel.cpp']
        changed = relocate(command, parent, root, oldhost, host)
        self.assertEqual(changed, ['make', 'RTL_DIR=/external/new/core/candidate/rtl',
            'OBJDIR=/external/new/core/obj', 'VL_J=32',
            'VL_EXTRA_DEFINES=+define+VEN_FE_PIPE --assert',
            'CPP_SRCS=/external/new/core/tb_new.cpp /repo/memmodel.cpp'])
        self.assertEqual(command[1], 'RTL_DIR=/external/prior/core/candidate/rtl')

    def test_missing_model_local_host_rejected(self):
        parent, root = Path('/external/prior/core'), Path('/external/new/core')
        with self.assertRaises(AssertionError):
            relocate(['RTL_DIR='+str(parent/'candidate'), 'OBJDIR='+str(parent/'obj')],
                     parent, root, parent/'missing.cpp', root/'tb_new.cpp')


if __name__ == '__main__':
    unittest.main()
