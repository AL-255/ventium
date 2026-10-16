import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

import prune_archived_pch as subject


class ArchivedPch(unittest.TestCase):
    def test_strict_generated_names_only(self):
        self.assertTrue(subject.pch('obj/Vtb__pch.h.fast.gch'))
        self.assertTrue(subject.pch('obj/Vcore__pch.h.slow.gch'))
        for name in ('obj/manual.gch','obj/Vtb.cpp','obj/Vtb__pch.h','obj/program',
                     'source/pch.h.fast.gch','obj/Vtb__pch.h.fast.gch.backup'):
            self.assertFalse(subject.pch(name))
        for name in ('/obj/Vtb__pch.h.fast.gch','../obj/Vtb__pch.h.fast.gch'):
            with self.assertRaises(AssertionError): subject.pch(name)

    def test_retains_every_other_member_and_metadata(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as temp:
            root=Path(temp);original=root/'old.tar.zst';new=root/'new.tar.zst'
            data=io.BytesIO()
            with tarfile.open(fileobj=data,mode='w') as archive:
                for name,payload in (('obj/Vtb__pch.h.fast.gch',b'cache'),
                                     ('obj/Vtb.cpp',b'source'),('obj/test',b'binary'),
                                     ('obj/manual.gch',b'not-generated')):
                    member=tarfile.TarInfo(name);member.size=len(payload);member.mode=0o751
                    member.mtime=123456789;member.uid=1000;member.gid=1000
                    member.pax_headers={'comment':'preserved'}
                    archive.addfile(member,io.BytesIO(payload))
            original.write_bytes(subprocess.check_output(['zstd','-q','-c'],input=data.getvalue()))
            kept,removed=subject.inventory(original)
            self.assertEqual([row['name'] for row in removed],['obj/Vtb__pch.h.fast.gch'])
            data=io.BytesIO()
            with tarfile.open(fileobj=data,mode='w|') as archive:
                self.assertEqual(subject.inventory(original,archive),(kept,removed))
            new.write_bytes(subprocess.check_output(['zstd','-q','-c'],input=data.getvalue()))
            self.assertEqual(subject.inventory(new),(kept,[]))
            self.assertEqual(len(kept),3)

    def test_collect_only_absolute_hash_keys(self):
        protected=set()
        subject.collect_pins({'pins':{'/tmp/input': '1'*64},'path':'/tmp/cache','note':'x'},protected)
        self.assertEqual(protected,{'/tmp/input'})


if __name__=='__main__': unittest.main()
