"""Invocation contract tests; these do not execute or fabricate guest traces."""
from pathlib import Path
import unittest

from run_smsw_corners import admitted, command


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Path('/retained/case')
        self.old = ['taskset', '-c', '4,5', 'timeout', '--kill-after=2s', '20s',
            '/old/obj/tb_ventium', '--system', '--cosim', '--cycle-func', '--l1-axi',
            '--image', '/retained/case/probe.bin', '--out', '/retained/case/candidate.vtrace',
            '--max-insn', '3000', '--max-cycles', '1000000', '--quiesce', '4096',
            '+ven_faultlog', '+ven_seglog']

    def test_only_model_and_output_change(self):
        old = list(self.old)
        result = command(old, Path('/new/obj/tb_ventium'), self.fixture, Path('/new/candidate.vtrace'))
        expected = self.old[6:]
        expected[0] = '/new/obj/tb_ventium'
        expected[expected.index('--out') + 1] = '/new/candidate.vtrace'
        self.assertEqual(result, expected)
        self.assertEqual(old, self.old)

    def test_guard_options_and_cold_image_cannot_drift(self):
        for token in ('--l1-axi', '--cycle-func', '--system', '--cosim', '3000',
                      '1000000', '4096', '/retained/case/probe.bin'):
            with self.subTest(token=token), self.assertRaises(AssertionError):
                broken = list(self.old)
                broken[broken.index(token)] = 'changed'
                command(broken, Path('/new/model'), self.fixture, Path('/new/out'))
        for option in ('--restore', '--dbg-step', '--dbg-bp', '--no-trace', '--mask-x87'):
            with self.subTest(option=option), self.assertRaises(AssertionError):
                command(self.old + [option], Path('/new/model'), self.fixture, Path('/new/out'))

    def test_wrapper_and_native_identity_required(self):
        for index in (0, 1, 3, 4, 5, 6):
            with self.subTest(index=index), self.assertRaises(AssertionError):
                broken = list(self.old)
                broken[index] = 'unreviewed'
                command(broken, Path('/new/model'), self.fixture, Path('/new/out'))

    def test_only_complete_native_observation_admits(self):
        model = Path('/new/model')
        argv = [str(model), '--cycle-func', '--l1-axi']
        sample = dict(exe=str(model), argv=argv, affinity=[12], cgroup='0::/owned\n')
        self.assertTrue(admitted(sample, model, argv, 12, '0::/owned\n'))
        for key, wrong in (('exe', '/usr/bin/taskset'), ('argv', ['']),
                           ('argv', ['taskset', '-c', '12', *argv]),
                           ('argv', [str(model), '--cycle-func']),
                           ('affinity', [12, 13]), ('affinity', [13]),
                           ('cgroup', '0::/different\n')):
            with self.subTest(key=key, value=wrong):
                self.assertFalse(admitted(dict(sample, **{key: wrong}), model, argv, 12, '0::/owned\n'))


if __name__ == '__main__':
    unittest.main()
