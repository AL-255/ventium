"""The private relink must preserve flags and replace exactly one object."""
from pathlib import Path
import unittest

import build


class Commands(unittest.TestCase):
    def test_compile_scope(self):
        command = ['cc', '-m64', '-O2', '-g', '-DNEED_CPU_H', '-iquote', '.',
                   '-MD', '-MQ', 'old.o', '-MF', 'old.d', '-o', 'old.o', '-c', '../original.c']
        self.assertEqual(build.private_flags(command, Path('/source/accel/tcg/tb-maint.c')),
                         ['-iquote', '/source/accel/tcg', '-m64', '-O2', '-g',
                          '-DNEED_CPU_H', '-iquote', '.'])

    def test_compile_malformed(self):
        with self.assertRaises(ValueError):
            build.private_flags(['cc', '-O2', '-o'], Path('/source/tb-maint.c'))

    def test_link_scope(self):
        before = ['cc', '-o', 'qemu-system-i386', 'a.o', 'old.o', '-Wl,--as-needed', 'b.a', '-pthread']
        after = build.private_link(before, 'old.o', '/private/new.o', '/private/qemu')
        self.assertEqual(after, ['cc', '-o', '/private/qemu', 'a.o', '/private/new.o',
                                 '-Wl,--as-needed', 'b.a', '-pthread'])
        self.assertEqual(before[2], 'qemu-system-i386')

    def test_link_ambiguous(self):
        for command in (['cc', '-o', 'qemu', 'a.o'], ['cc', '-o', 'qemu', 'old.o', 'old.o'],
                        ['cc', '-o', 'qemu', 'old.o', '-o', 'second']):
            with self.assertRaises(ValueError):
                build.private_link(command, 'old.o', 'new.o', 'private')


if __name__ == '__main__':
    unittest.main()
