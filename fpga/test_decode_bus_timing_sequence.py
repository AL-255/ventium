"""Owner-wait checks; no systemd/Vivado launch or artifact writes."""
import io
import json
import os
import time
import unittest
from unittest.mock import patch

import run_decode_bus_timing_sequence as seq


class OwnerWait(unittest.TestCase):
    def state(self, **changes):
        return dict(InvocationID='a'*32, MainPID='0', SubState='exited',
                    ExecMainStatus='0', Result='success') | changes

    def wait(self, states, deadline=None):
        stream = io.StringIO()
        with patch.object(seq, 'props', side_effect=states), patch.object(seq.time, 'sleep'):
            result = seq.wait_closed('fixture.service', 'a'*32,
                                     time.monotonic()+10 if deadline is None else deadline, stream)
        return result, stream.getvalue()

    def test_terminal_success_only(self):
        state, output = self.wait([self.state()])
        self.assertEqual(state, self.state())
        self.assertEqual(output, '')
        for changes in ({'ExecMainStatus':'1'}, {'SubState':'failed'}, {'Result':'timeout'},
                        {'InvocationID':'b'*32}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.wait([self.state(**changes)])

    def test_live_process_observed_then_same_owner_closes(self):
        live = self.state(MainPID=str(os.getpid()), SubState='running')
        state, output = self.wait([live, self.state()])
        record = json.loads(output)
        self.assertEqual(record['owner']['MainPID'], str(os.getpid()))
        self.assertTrue(record['process']['stat'])
        self.assertTrue(record['process']['cmdline'])
        self.assertTrue(record['process']['cgroup'].startswith('0::'))
        self.assertEqual(state['MainPID'], '0')

    def test_live_owner_deadline_is_not_success(self):
        with self.assertRaisesRegex(ValueError, 'deadline; no restart'):
            self.wait([self.state(MainPID=str(os.getpid()), SubState='running')], deadline=0)

    def test_process_exit_observation_race_rechecks_exact_owner(self):
        state, output = self.wait([
            self.state(MainPID='999999999', SubState='running'), self.state()])
        self.assertEqual(output, '')
        self.assertEqual(state, self.state())
        with self.assertRaisesRegex(ValueError, 'owner changed'):
            self.wait([self.state(MainPID='999999999', SubState='running'),
                       self.state(InvocationID='b'*32)])


if __name__ == '__main__':
    unittest.main()
