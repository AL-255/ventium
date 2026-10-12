"""Check regression scheduling without launching or weakening any native gate."""
from pathlib import Path
import unittest

import run_fp_high_valid_regressions as driver


class PlanTests(unittest.TestCase):
    def test_complete_suite_and_explicit_models(self):
        parent,candidate,root=map(Path,('/parent','/candidate','/output'))
        rows=driver.plan(parent,candidate,root)
        self.assertEqual([r[0] for r in rows],
            ['boundary-0','boundary-1','boundary-24','boundary-25','boundary-29','boundary-4093',
             'faults','integer','memory','held','branch','replay'])
        for label,command,cap in rows:
            self.assertEqual(command[:2],['/usr/bin/python3','-B'])
            self.assertTrue(Path(command[2]).is_file())
            self.assertEqual(command[-2:],['--out',str(root/label)])
            self.assertGreater(cap,0)
            self.assertLessEqual(cap,420)
            model=command[command.index('--candidate')+1]
            expected='/candidate' if label in ('faults','replay') else '/candidate/obj/tb_ventium'
            self.assertEqual(model,expected)
            self.assertNotIn('--functional',command)
            self.assertNotIn('--max-insn',command)

    def test_every_boundary_keeps_both_instruction_alignments(self):
        rows=driver.plan(Path('/p'),Path('/c'),Path('/o'))[:6]
        for (label,command,_),offset in zip(rows,(0,1,24,25,29,4093),strict=True):
            self.assertEqual(command[command.index('--operand-offset')+1],str(offset))
            self.assertEqual([command[i+1] for i,v in enumerate(command) if v=='--offset'],['0','31'])
            self.assertEqual(command[command.index('--kind')+1],'1')
            self.assertEqual(command[command.index('--workers')+1],'8')

    def test_full_integer_memory_and_branch_matrices_not_trimmed(self):
        rows=driver.plan(Path('/p'),Path('/c'),Path('/o'))
        for label,command,_ in rows[6:]:
            self.assertNotIn('--offset',command,label)
            self.assertNotIn('--kind',command,label)
            self.assertNotIn('--operand-offset',command,label)

    def test_serial_fault_budget_covers_complete_matrix(self):
        rows=driver.plan(Path('/p'),Path('/c'),Path('/o'))
        _,command,cap=next(row for row in rows if row[0]=='faults')
        self.assertEqual(cap,420)
        self.assertGreater(cap,32*8.13)
        self.assertEqual(command[2],str(driver.REPO/'verif/l1/run_fp_read_ack_faults.py'))
        self.assertNotIn('--timeout',command)


if __name__=='__main__': unittest.main()
