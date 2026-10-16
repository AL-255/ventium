import unittest

import run_next_ready_ui_build as run


class WaitOwner(unittest.TestCase):
    def test_only_exact_terminal_owner_can_build(self):
        live = dict(LoadState='loaded',ActiveState='active',SubState='running',MainPID='123',
                    InvocationID=run.INVOCATION,Result='success',ExecMainStatus='0')
        self.assertEqual(run.disposition(live),'wait')
        ended = dict(live,SubState='exited',MainPID='0')
        self.assertEqual(run.disposition(ended),'build')
        for changed in (dict(ended,InvocationID='0'*32),dict(ended,LoadState='not-found'),
                        dict(ended,ExecMainStatus='1'),dict(ended,Result='timeout'),
                        dict(ended,SubState='failed'),dict(live,MainPID='0')):
            with self.assertRaises(AssertionError): run.disposition(changed)


if __name__ == '__main__': unittest.main()
