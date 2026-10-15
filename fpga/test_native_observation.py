import unittest
from types import SimpleNamespace

from native_observation import retry_owned_observation


class Checks(unittest.TestCase):
    def child(self):
        return SimpleNamespace(pid=123, returncode=None, poll=lambda: None)

    def test_transient_incomplete_observation_is_retried_not_accepted(self):
        attempts = []
        def read():
            attempts.append(1)
            if len(attempts) == 1: raise AssertionError('incomplete proc argv')
            return {'verified': True}
        observed, errors = retry_owned_observation(self.child(), read, .1)
        self.assertEqual(observed, {'verified': True})
        self.assertEqual(len(attempts), 2)
        self.assertEqual(errors, ["AssertionError('incomplete proc argv')"])

    def test_persistent_bad_identity_times_out(self):
        def read(): raise AssertionError('wrong executable or arguments')
        with self.assertRaisesRegex(RuntimeError, 'observation timeout'):
            retry_owned_observation(self.child(), read, .02)

    def test_child_exit_before_or_during_observation_fails(self):
        dead = SimpleNamespace(pid=123, returncode=7, poll=lambda: 7)
        with self.assertRaisesRegex(RuntimeError, 'exited before'):
            retry_owned_observation(dead, lambda: self.fail('must not read dead child'))
        values = iter([None, 0])
        dies = SimpleNamespace(pid=123, returncode=0, poll=lambda: next(values))
        with self.assertRaisesRegex(RuntimeError, 'exited during'):
            retry_owned_observation(dies, lambda: {'verified': True})


if __name__ == '__main__': unittest.main()
