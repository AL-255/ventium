"""Run the launcher's actual failure cleanup; no service or board is touched."""
import ast
import io
import json
from pathlib import Path
import types
import unittest

from ven_cold_owners import OwnedServices


source = Path(__file__).with_name('ven_cold_start.py')
outer = [n for n in ast.parse(source.read_text()).body if isinstance(n, ast.Try)]
assert len(outer) == 1 and outer[0].finalbody
cleanup = compile(ast.fix_missing_locations(ast.Module(
    body=outer[0].finalbody, type_ignores=[])), str(source), 'exec')


class Receipt(io.StringIO):
    def close(self):
        pass


class StartCleanupTests(unittest.TestCase):
    def setUp(self):
        self.actions = []
        self.receipt = Receipt()
        self.states = {}
        self.owners = {}
        for i, name in enumerate(('capture.service', 'daemon.service', 'watch.service'), 1):
            state = dict(Id=name, InvocationID=str(i)*32, MainPID=str(i),
                         ActiveState='active', SubState='running', TasksCurrent='1')
            self.states[name] = state
            self.owners[name] = OwnedServices({name:state},
                lambda key:dict(self.states[key]), self.stop, self.signal)
        # Only receipt I/O is exposed; hardware/subprocess access would fail.
        class Root:
            def __truediv__(inner, name):
                self.assertEqual(name, 'failed-start-cleanup.json')
                return types.SimpleNamespace(open=self.open)
        self.env = dict(ROOT=Root(), watcher_owned=False, watcher_unit='watch',
                        worker_owners=self.owners, json=json)

    def open(self, mode):
        self.assertEqual(mode, 'x')
        self.actions.append(('receipt',))
        return self.receipt

    def signal(self, name, sig):
        self.fail('failure cleanup must not signal a name without checked stop')

    def stop(self, name):
        self.actions.append(('stop', name))
        self.states[name].update(InvocationID='', MainPID='0', TasksCurrent='0',
                                 ActiveState='inactive', SubState='dead')

    def run_cleanup(self):
        exec(cleanup, self.env)
        return json.loads(self.receipt.getvalue())

    def test_watcher_stops_before_workers_and_no_hardware_cleanup(self):
        result = self.run_cleanup()
        self.assertEqual(self.actions[:3], [('stop','watch.service'),
            ('stop','capture.service'), ('stop','daemon.service')])
        self.assertEqual(result['errors'], [])
        self.assertFalse(result['hardware_writes_by_launcher_cleanup'])
        self.assertTrue(result['guest_state_requires_inspection'])
        self.assertFalse(result['acceptance'])

    def test_replacement_is_not_stopped_but_other_owners_are(self):
        self.states['daemon.service']['InvocationID'] = 'e'*32
        result = self.run_cleanup()
        self.assertNotIn(('stop','daemon.service'), self.actions)
        self.assertIn(('stop','capture.service'), self.actions)
        self.assertEqual(result['errors'][0]['unit'], 'daemon.service')

    def test_stop_failure_does_not_abandon_other_owners(self):
        def fail(name): raise RuntimeError('simulated stop failure')
        self.owners['watch.service'].stop_callback = fail
        result = self.run_cleanup()
        self.assertIn(('stop','capture.service'), self.actions)
        self.assertIn(('stop','daemon.service'), self.actions)
        self.assertEqual(result['errors'][0]['unit'], 'watch.service')

    def test_unobserved_services_are_never_adopted_by_name(self):
        del self.owners['daemon.service']
        del self.owners['watch.service']
        result = self.run_cleanup()
        self.assertEqual(result['observed_units'], ['capture.service'])
        self.assertEqual(self.actions, [('stop','capture.service'), ('receipt',)])

    def test_no_observed_worker_still_requires_inspection(self):
        self.owners.clear()
        result = self.run_cleanup()
        self.assertEqual(result['observed_units'], [])
        self.assertTrue(result['guest_state_requires_inspection'])

    def test_successful_handoff_leaves_cleanup_to_watcher(self):
        self.env['watcher_owned'] = True
        exec(cleanup, self.env)
        self.assertEqual(self.actions, [])

    def test_receipt_failure_happens_after_owned_workers_reaped(self):
        def fail(mode): raise OSError('simulated full output volume')
        self.open = fail
        with self.assertRaises(OSError): self.run_cleanup()
        self.assertEqual(len(self.actions), 3)
        for owner in self.owners.values(): owner.require_closed()


if __name__ == '__main__':
    unittest.main()
