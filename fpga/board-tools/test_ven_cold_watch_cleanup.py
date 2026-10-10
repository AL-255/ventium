"""Execute the real watcher's complete finally block with fake services/MMIO.

These tests do not certify a board run. They do prevent replacing lifecycle
tests with tests of the sampling prefix alone.
"""
import ast
import types
from pathlib import Path
import unittest
from ven_cold_owners import OwnedServices, OwnershipError
from ven_quake_ipc import Accumulator

source=Path(__file__).with_name('ven_cold_watch.py')
tree=ast.parse(source.read_text())
outer=[n for n in tree.body if isinstance(n,ast.Try)]
assert len(outer)==1 and outer[0].finalbody
cleanup=compile(ast.fix_missing_locations(ast.Module(body=outer[0].finalbody,type_ignores=[])),str(source),'exec')
whole=compile(ast.fix_missing_locations(ast.Module(body=outer,type_ignores=[])),str(source),'exec')


class WatcherCleanupTests(unittest.TestCase):
    def setUp(self):
        self.actions=[];self.saved=[];self.fail_receipt=None
        self.states={name:dict(Id=name,InvocationID=c*32,MainPID=str(pid),
            ActiveState='active',SubState='running',TasksCurrent='1')
            for name,c,pid in [('capture.service','c',11),('daemon.service','d',22)]}
        self.owners=OwnedServices(self.states,lambda name:dict(self.states[name]),self.stop,
            lambda name,sig:self.actions.append(('signal',name,sig)))
        self.ctrl=types.SimpleNamespace(close=lambda:self.actions.append(('close','ctrl')))
        self.guest=types.SimpleNamespace(close=lambda:self.actions.append(('close','guest')))
        def read(ctrl,off):
            self.assertIs(ctrl,self.ctrl)
            self.actions.append(('read',off))
            return 0xa0486501 if off==0 else 1
        probe=types.SimpleNamespace(R_IDENT=0,IDENT_MAGIC=0xa0486501,
            require_exec_debug=lambda ctrl:self.actions.append(('debug-admission',)),u32=read)
        def pack(fmt,ctrl,off,value):
            self.assertEqual((fmt,off,value),('<I',0x20,1));self.assertIs(ctrl,self.ctrl)
            self.actions.append(('reset',))
        self.env=dict(owners=self.owners,OwnershipError=OwnershipError,save=self.save,
            ctrl=self.ctrl,guest=self.guest,fd=42,probe=probe,probe_path=Path('/pinned/probe.py'),
            struct=types.SimpleNamespace(pack_into=pack),command=self.command,
            gameplay=Accumulator(),image_sha='1'*64,rc=1,
            os=types.SimpleNamespace(close=lambda fd:self.actions.append(('close',fd))))

    def stop(self,name):
        self.actions.append(('stop',name))
        self.states[name].update(InvocationID='',MainPID='0',TasksCurrent='0',ActiveState='inactive',SubState='dead')

    def save(self,name,value):
        self.saved.append((name,value))
        if name==self.fail_receipt: raise OSError('simulated full output volume')

    def command(self,name,argv):
        self.actions.append(('clock',name));return 0

    def run_cleanup(self): exec(cleanup,self.env)

    def assert_no_reset_clock(self):
        self.assertFalse(any(a[0] in ('reset','clock') for a in self.actions))

    def assert_mappings_closed(self):
        self.assertEqual(self.actions[-3:],[('close','guest'),('close','ctrl'),('close',42)])

    def test_all_owned_workers_reaped_before_reset_and_clock(self):
        self.run_cleanup()
        reset=self.actions.index(('reset',))
        self.assertLess(self.actions.index(('stop','capture.service')),reset)
        self.assertLess(self.actions.index(('stop','daemon.service')),reset)
        self.assert_mappings_closed()
        self.assertTrue(dict(self.saved)['watch-closed.json']['clock_restored'])

    def test_replaced_capture_never_stopped_and_no_hardware_writes(self):
        self.states['capture.service']['InvocationID']='e'*32
        with self.assertRaises(OwnershipError): self.run_cleanup()
        self.assertNotIn(('stop','capture.service'),self.actions)
        self.assertIn(('stop','daemon.service'),self.actions)
        self.assert_no_reset_clock();self.assert_mappings_closed()
        self.assertTrue(dict(self.saved)['cleanup-refused.json']['cleanup_reset_clock_skipped'])

    def test_stop_failure_does_not_skip_other_owned_cleanup(self):
        def stop(name):
            if name=='capture.service': raise RuntimeError('simulated stop failure')
            self.stop(name)
        self.owners.stop_callback=stop
        with self.assertRaises(OwnershipError): self.run_cleanup()
        self.assertIn(('stop','daemon.service'),self.actions)
        self.assert_no_reset_clock();self.assert_mappings_closed()

    def test_remaining_native_tasks_refuse_clock_switch(self):
        def stop(name):
            self.actions.append(('stop',name))
            self.states[name].update(MainPID='0',TasksCurrent='1',SubState='exited')
        self.owners.stop_callback=stop
        with self.assertRaises(OwnershipError): self.run_cleanup()
        self.assert_no_reset_clock();self.assert_mappings_closed()

    def test_refusal_receipt_failure_cannot_fall_through_to_reset(self):
        self.states['capture.service']['InvocationID']='e'*32
        self.fail_receipt='cleanup-refused.json'
        with self.assertRaises(OSError): self.run_cleanup()
        self.assert_no_reset_clock();self.assert_mappings_closed()

    def test_preclock_receipt_failure_still_reaps_and_closes(self):
        self.fail_receipt='owners-before-clock-restore.json'
        with self.assertRaises(OSError): self.run_cleanup()
        self.owners.require_closed()
        self.assert_no_reset_clock();self.assert_mappings_closed()

    def test_aggregate_receipt_failure_occurs_after_hardware_cleanup(self):
        self.fail_receipt='gameplay-observation.json'
        with self.assertRaises(OSError): self.run_cleanup()
        self.assertIn(('reset',),self.actions)
        self.assertIn(('clock','restore-40.txt'),self.actions)
        self.assert_mappings_closed()

    def test_no_mmio_mapping_reaps_but_never_writes_hardware(self):
        self.env.update(fd=None,ctrl=None,guest=None)
        with self.assertRaisesRegex(RuntimeError,'no admitted MMIO'): self.run_cleanup()
        self.owners.require_closed();self.assert_no_reset_clock()
        self.assertFalse(any(a[0]=='close' for a in self.actions))

    def test_real_try_covers_guest_mapping_failure(self):
        self.env.update(fd=None,ctrl=None,guest=None)
        self.env['probe'].open_mmio=lambda **kwargs:(42,self.ctrl,None)
        self.env['probe'].DDR_BASE=0x60000000
        def fail_map(*args,**kwargs): raise OSError('simulated guest map failure')
        self.env['probe'].map_region=fail_map
        with self.assertRaisesRegex(OSError,'guest map'): exec(whole,self.env)
        self.owners.require_closed()
        self.assertEqual(self.actions[-2:],[('close','ctrl'),('close',42)])
        self.assertIn(('reset',),self.actions)

    def test_late_replacement_before_hardware_is_refused(self):
        def save(name,value):
            self.saved.append((name,value))
            if name=='owners-before-clock-restore.json':
                self.states['daemon.service'].update(InvocationID='e'*32,MainPID='55',
                    TasksCurrent='1',SubState='running',ActiveState='active')
        self.env['save']=save
        with self.assertRaises(OwnershipError): self.run_cleanup()
        self.assert_no_reset_clock();self.assert_mappings_closed()

if __name__=='__main__':unittest.main()
