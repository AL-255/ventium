"""Native-owner lifecycle checks, with all systemd and MMIO effects faked."""
import copy
import unittest
from ven_cold_owners import OwnedServices, OwnershipError


class OwnerTests(unittest.TestCase):
    def setUp(self):
        self.states = {name:dict(Id=name,InvocationID=letter*32,MainPID=str(pid),
            ActiveState='active',SubState='running',TasksCurrent='1')
            for name,letter,pid in [('capture.service','c',111),('guest.service','d',222)]}
        self.calls=[]
        self.owner=OwnedServices(self.states,lambda name:dict(self.states[name]),
                                 self.stop,self.signal)

    def stop(self,name):
        self.calls.append(('stop',name))
        self.states[name].update(InvocationID='',MainPID='0',ActiveState='inactive',
                                 SubState='dead',TasksCurrent='[not set]')

    def signal(self,name,signal): self.calls.append((signal,name))

    def test_synchronous_stop_and_repeated_cleanup(self):
        self.assertEqual(len(self.owner.close_all()),2)
        self.owner.close_all()
        self.assertEqual(self.calls,[('stop','capture.service'),('stop','guest.service')])

    def test_natural_exit_retains_original_identity(self):
        for state in self.states.values():
            state.update(MainPID='0',SubState='exited',TasksCurrent='0')
        self.owner.close_all(); self.assertFalse(self.calls)

    def test_replaced_owner_never_stopped_or_clock_admitted(self):
        self.states['capture.service']['InvocationID']='e'*32
        with self.assertRaisesRegex(OwnershipError,'replaced invocation'): self.owner.close_all()
        self.assertEqual(self.calls,[('stop','guest.service')])
        with self.assertRaises(OwnershipError): self.owner.require_closed()

    def test_pid_replacement_is_refused_even_same_invocation(self):
        self.states['guest.service']['MainPID']='333'
        with self.assertRaisesRegex(OwnershipError,'PID'): self.owner.signal('guest.service','SIGUSR1')
        self.assertFalse(self.calls)

    def test_unobserved_disappearance_is_not_success(self):
        self.states['guest.service'].update(InvocationID='',MainPID='0',TasksCurrent='0')
        with self.assertRaises(OwnershipError): self.owner.stop('guest.service')
        self.assertFalse(self.calls)

    def test_residual_worker_is_stopped_not_declared_closed(self):
        self.states['guest.service'].update(MainPID='0',SubState='exited',TasksCurrent='1')
        with self.assertRaises(OwnershipError): self.owner.require_closed()
        self.owner.stop('guest.service')
        self.assertEqual(self.calls,[('stop','guest.service')])

    def test_missing_tasks_is_not_quiescence(self):
        state=self.states['guest.service']
        state.update(MainPID='0',SubState='exited');del state['TasksCurrent']
        with self.assertRaises(OwnershipError): self.owner.require_closed()

    def test_stop_failure_still_closes_other_owner(self):
        def fail(name):
            if name=='capture.service': raise RuntimeError('stop timed out')
            self.stop(name)
        self.owner.stop_callback=fail
        with self.assertRaisesRegex(OwnershipError,'timed out'): self.owner.close_all()
        self.assertEqual(self.calls,[('stop','guest.service')])

    def test_replacement_after_our_stop_refuses_mutation(self):
        def replaced(name):
            self.stop(name)
            self.states[name].update(InvocationID='e'*32,MainPID='444',
                                    ActiveState='active',SubState='running',TasksCurrent='1')
        self.owner.stop_callback=replaced
        with self.assertRaises(OwnershipError): self.owner.stop('guest.service')
        self.assertEqual(self.calls,[('stop','guest.service')])

    def test_late_replacement_after_all_stopped(self):
        self.owner.close_all()
        self.states['guest.service'].update(InvocationID='e'*32,MainPID='0')
        with self.assertRaises(OwnershipError): self.owner.require_closed()

    def test_signal_lifecycle(self):
        self.owner.signal('capture.service','SIGUSR1')
        self.assertEqual(self.calls,[('SIGUSR1','capture.service')])
        self.states['capture.service'].update(MainPID='0',SubState='exited',TasksCurrent='0')
        self.owner.signal('capture.service','SIGUSR1')
        self.assertEqual(len(self.calls),1)

    def test_initial_owner_validation(self):
        for field,value in [('InvocationID',''),('InvocationID','z'*32),('Id','other.service'),
                            ('MainPID','0'),('MainPID','-1'),('MainPID','12x'),('MainPID',True),
                            ('SubState','exited')]:
            states=copy.deepcopy(self.states);states['guest.service'][field]=value
            with self.subTest(field=field,value=value),self.assertRaises(OwnershipError):
                OwnedServices(states,lambda name:states[name],self.stop,self.signal)

if __name__=='__main__':unittest.main()
