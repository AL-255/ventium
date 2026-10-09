"""Bounds checks prevent treating an uncached or fabricated image as low RAM."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('lowram',Path(__file__).with_name('prepare-coremark-lowram.py'))
lowram=importlib.util.module_from_spec(spec);spec.loader.exec_module(lowram)

class Placement(unittest.TestCase):
    def setUp(self):
        self.image=dict(regs=dict(eip='0x08048000',esp='0x05d55ff0'),
            meta=dict(cpu='pentium',seed=1234),regions=[
                dict(vaddr='0x08048000',hex='90'),
                dict(vaddr='0x05d55000',len=4096,zero=True)])

    def test_valid(self):
        self.assertEqual(lowram.audit_image(self.image)['highest_byte'],0x08048000)

    def test_reject_boundaries_and_missing_register_coverage(self):
        for mutation in ('pci','hole','wrap','end','empty','entry','stack','cpu'):
            image=copy.deepcopy(self.image)
            if mutation=='pci': image['regions'][1]['vaddr']='0x407ff000'
            if mutation=='hole': image['regions'][0]['vaddr']='0x000a0000'
            if mutation=='wrap': image['regions'][1].update(vaddr='0xfffff000',len=8192)
            if mutation=='end': image['regions'][1].update(vaddr='0x0ffff000',len=8192)
            if mutation=='empty': image['regions'][1]['len']=0
            if mutation=='entry': image['regs']['eip']='0x08049000'
            if mutation=='stack': image['regs']['esp']='0x05d56000'
            if mutation=='cpu': image['meta']['cpu']='qemu32'
            with self.subTest(mutation=mutation),self.assertRaises(AssertionError):
                lowram.audit_image(image)

if __name__=='__main__': unittest.main()
