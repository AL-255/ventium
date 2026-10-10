import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('demand_driver',Path(__file__).with_name('run-sfetch16-demand.py'))
driver=importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class Ports(unittest.TestCase):
    def test_unique_full_corpus(self):
        cases=list(range(2880))
        ports=driver.assign_gdb_ports(cases,20000,32768)
        self.assertEqual(len(set(ports.values())),len(cases))
        self.assertEqual((min(ports.values()),max(ports.values())),(20000,22879))

    def test_reject_overlap_privileged_empty_and_duplicate(self):
        for cases,base in (([1,2],32767),([1],1023),([],20000),([1,1],20000)):
            with self.subTest(cases=cases,base=base),self.assertRaises(AssertionError):
                driver.assign_gdb_ports(cases,base,32768)

    def test_exact_upper_bound(self):
        self.assertEqual(driver.assign_gdb_ports([1,2],32766,32768),{1:32766,2:32767})

    def test_real_axi_activity_required(self):
        row='[L1DPERF] fill cycles=12 backing-wait=3 backing-ack=9\n'
        self.assertEqual(driver.axi_activity(row),(12,3,9))
        for bad in ('',row+row,row.replace('ack=9','ack=0'),row.replace('cycles=12','cycles=0')):
            with self.subTest(bad=bad),self.assertRaises(AssertionError):
                driver.axi_activity(bad)


if __name__=='__main__': unittest.main()
