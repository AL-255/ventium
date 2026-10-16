import unittest
from run_hosted_resync import cases, grade


class HostedResyncTests(unittest.TestCase):
    def test_matrix(self):
        all_cases=cases()
        self.assertEqual(len(all_cases),160)
        self.assertEqual(len(set(all_cases)),160)
        self.assertEqual(sum(c[0]=='candidate' for c in all_cases),144)
        self.assertEqual(len(cases(True)),32)

    def test_grade_owns_case_and_completion(self):
        case=('candidate',40000000,1,0,1,0)
        text='HOSTED-RESYNC-OK hz=40000000 mouse=0 reset=1 point=0 aborts=1 completed=1 edges=12'
        self.assertTrue(grade(case,0,text))
        for bad in (text.replace('aborts=1','aborts=0'),text.replace('reset=1','reset=0'),
                    text.replace('completed=1','completed=2'),text+'\n'+text,text+' FATAL'):
            self.assertFalse(grade(case,0,bad))
        self.assertFalse(grade(case,1,text))

    def test_red_is_not_arbitrary_failure(self):
        case=('parent',40000000,0,1,1,0)
        self.assertTrue(grade(case,1,'FATAL: RESYNC-INHIBIT-MISSING'))
        self.assertFalse(grade(case,0,'RESYNC-INHIBIT-MISSING'))
        self.assertFalse(grade(case,1,'FATAL: bounded hosted-resync timeout'))


if __name__ == '__main__': unittest.main()
