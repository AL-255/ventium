#!/usr/bin/env python3
"""Journal path normalization must retain exact builder/argument checks."""
import unittest
from audit_parallel_tag_core import REPO, builder_command_matches


class JournalCommandTests(unittest.TestCase):
    def command(self, path=None):
        return (f'/usr/bin/python3 -B {REPO}/verif/l1/build_parallel_tag_core.py '
                f'--parent {REPO} --checks {REPO} --out {path or REPO}')

    def matches(self, command, **kwargs):
        return builder_command_matches(command, REPO, REPO, REPO, **kwargs)

    def test_canonical_and_alias(self):
        self.assertTrue(self.matches(self.command()))
        self.assertTrue(self.matches(self.command(REPO/'verif/..')))

    def test_manager_period_is_not_a_path_suffix(self):
        message = 'Started ventium-ipc-parallel32.scope - [systemd-run] '+self.command()+'.'
        self.assertTrue(self.matches(message, manager=True))
        self.assertFalse(self.matches(message))
        self.assertFalse(self.matches(message[:-1], manager=True))

    def test_other_target_and_extra_args_rejected(self):
        self.assertFalse(self.matches(self.command(REPO/'verif')))
        self.assertFalse(self.matches(self.command()+' --out '+str(REPO)))
        self.assertFalse(self.matches(self.command().replace('--checks', '--unrelated')))
        self.assertFalse(self.matches(self.command().replace('build_parallel_tag_core.py', 'other.py')))


if __name__ == '__main__':
    unittest.main()
