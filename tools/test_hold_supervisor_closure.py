import unittest
from hold_supervisor_closure import validate


class ClosureTests(unittest.TestCase):
    def setUp(self):
        self.expected = dict(unit='ventium-example.service', invocation_id='1'*32, owner_pid=123)
        self.live = dict(InvocationID='1'*32, MainPID='123', ActiveState='active', ExecMainExitTimestamp='')

    def test_live(self):
        self.assertFalse(validate(self.live, self.expected))

    def test_close_success_and_failure(self):
        for state in ('inactive', 'failed'):
            self.assertTrue(validate(dict(self.live, ActiveState=state, MainPID='0',
                ExecMainExitTimestamp='actual manager timestamp'), self.expected))

    def test_no_fabrication_after_gc(self):
        with self.assertRaises(ValueError):
            validate(dict(self.live, InvocationID='', ActiveState='inactive', MainPID='0'), self.expected)

    def test_reused_unit(self):
        with self.assertRaises(ValueError):
            validate(dict(self.live, InvocationID='2'*32), self.expected)

    def test_owner_changed(self):
        with self.assertRaises(ValueError):
            validate(dict(self.live, MainPID='456'), self.expected)

    def test_no_exit_timestamp(self):
        with self.assertRaises(ValueError):
            validate(dict(self.live, ActiveState='inactive', MainPID='0'), self.expected)


if __name__ == '__main__':
    unittest.main()
