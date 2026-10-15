"""Current-profile export boundaries; no processor or physical-board pass."""
import argparse
from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import freeze_aux_mouse_rk_candidate as export
from freeze_rk_candidate import FreezeError

SOURCE = OVERLAY = None


class Boundaries(unittest.TestCase):
    def setUp(self):
        required = ['VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_X87_MF_STRICT', 'VEN_KBC_FAST', 'VEN_KBD_AUTOACK']
        self.definitions = required+['SYNTHETIC_%d'%n for n in range(152)]
        self.old = dict(variant='pipe_wait_read_ack_timing', qualification='UNQUALIFIED', core_mhz=40,
            write_slots=16, l2_sets=1024, hardware_defines=self.definitions+['SYNTHESIS', 'VTM_NO_DPI'])
        pc, core = export.native.PROFILES['pipe-wait']
        self.started = dict(parent_profile='pipe-wait', parent_model=pc, directed_model=core,
            changes=[export.native.FILE], added_defines=[], command=['-D'+n for n in self.definitions]+
            ['-GBOARD_POSTED=1', '-GBOARD_WRITE_SLOTS=16'])
        self.closed = dict(passed=True, native_exit=0, inputs_unchanged=True)

    def check(self):
        export.check_profile(self.old, self.started, self.closed, self.definitions)

    def test_exact_profile(self): self.check()

    def test_old_core_or_unclosed_build_cannot_be_promoted(self):
        for where, key, value in (
            ('old','variant','backing_pair_payload_timing'), ('old','core_mhz',70),
            ('old','write_slots',1), ('old','l2_sets',512),
            ('started','parent_profile','early-bus'), ('started','parent_model','wrong'),
            ('started','directed_model','wrong'), ('started','changes',[]),
            ('started','added_defines',['UNREVIEWED']), ('closed','passed',False),
            ('closed','native_exit',1), ('closed','inputs_unchanged',False)):
            target = getattr(self,where); saved = deepcopy(target)
            target[key] = value
            with self.subTest(key=key), self.assertRaises(FreezeError): self.check()
            setattr(self,where,saved)

    def test_missing_or_extra_mode_is_rejected(self):
        for key in ('VEN_X87_MF_STRICT', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_KBC_FAST'):
            index = self.definitions.index(key)
            for new in ('VEN_CACHE_HALF', 'SYNTHETIC_0'):
                before = self.definitions[index]; self.definitions[index] = new
                with self.subTest(key=key,new=new), self.assertRaises(FreezeError): self.check()
                self.definitions[index] = before
        self.started['command'].remove('-GBOARD_WRITE_SLOTS=16')
        with self.assertRaises(FreezeError): self.check()

    def test_only_the_qualified_aux_line_may_change(self):
        source = (export.REPO/export.native.FILE).read_bytes()
        repaired = export.native.recipe.transform(source.decode()).encode()
        self.assertTrue(export.check_delta(export.AUX,source,repaired))
        self.assertFalse(export.check_delta('ventium/rtl/core/core.sv',b'unchanged',b'unchanged'))
        for name,before,after in ((export.AUX,source,source),(export.AUX,source,repaired+b'\n'),
                                ('ventium/rtl/core/core.sv',b'old',b'new')):
            with self.assertRaises(FreezeError): export.check_delta(name,before,after)

    def test_owner_identity_and_native_completion_required(self):
        owner = dict(SubState='exited',MainPID='0',ExecMainStatus='0',Result='success',InvocationID='exact')
        def text(row): return ''.join(k+'='+v+'\n' for k,v in row.items())
        with patch.object(export.subprocess,'check_output',return_value=text(owner)):
            self.assertEqual(export.closed_owner('fixture.service','exact'),owner)
        for key,value in (('SubState','running'),('MainPID','123'),('ExecMainStatus','1'),
                          ('Result','oom-kill'),('InvocationID','replacement')):
            with patch.object(export.subprocess,'check_output',return_value=text(owner|{key:value})):
                with self.assertRaises(FreezeError): export.closed_owner('fixture.service','exact')


class ExpandedProject(unittest.TestCase):
    def setUp(self):
        if SOURCE is None or OVERLAY is None: self.skipTest('supply --source and --overlay for native Tcl checks')
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertEqual(Path(os.environ['TMPDIR']).resolve(strict=True),scratch)
        self.assertEqual(export.sha256((SOURCE/'input-manifest.json').read_bytes()),export.PARENT)
        temp = tempfile.TemporaryDirectory(prefix='aux-mouse-contract-',dir=scratch)
        self.addCleanup(temp.cleanup); self.root = Path(temp.name)
        self.flow = self.root/'flow'; shutil.copytree(SOURCE/'flow',self.flow)
        prepared = json.loads((OVERLAY/'prepared.json').read_text())
        for name,h in prepared['files'].items():
            data = (OVERLAY/name).read_bytes();self.assertEqual(export.sha256(data),h)
            (self.flow/name).write_bytes(data)
        self.defs = self.root/'defines.txt';shutil.copyfile(SOURCE/'defines.txt',self.defs)

    def check(self,ok,diagnostic):
        run = subprocess.run(['tclsh',str(export.REPO/'fpga/test_aux_mouse_rk_wrapper.tcl'),
            str(SOURCE/'ventium/fpga/create_project_3mhz_wrapper.tcl'),str(self.flow),str(self.defs),
            str(SOURCE/'ventium'),str(SOURCE/'template'),'logic_only'],capture_output=True,text=True,timeout=15)
        self.assertEqual(run.returncode==0,ok,run.stdout+run.stderr)
        self.assertIn(diagnostic,run.stdout+run.stderr)

    def test_real_payload_composition_preserves_every_other_source(self):
        manifest=json.loads((SOURCE/'input-manifest.json').read_text())
        original={}
        for row in manifest['files']:
            data=(SOURCE/row['frozen']).read_bytes()
            self.assertEqual(export.sha256(data),row['sha256'])
            original[row['frozen']]=data
        current=dict(original)
        current[export.AUX]=export.native.recipe.transform(original[export.AUX].decode()).encode()
        self.assertEqual(export.sha256(current[export.AUX]),export.native.evidence.CANDIDATE)
        overlay=json.loads((OVERLAY/'prepared.json').read_text())
        extension={n:(OVERLAY/n).read_bytes() for n in overlay['files']}
        combined=export.mouse.integrate(current,extension)
        self.assertEqual(len(combined),192)
        self.assertEqual({n for n in original if combined[n]!=original[n]},
                         {export.AUX}|{'flow/'+n for n in export.mouse.TRANSFORMS})
        self.assertEqual(export.base.source_closure({n:dict(data=b) for n,b in combined.items()}),
                         manifest['source_closure'])

    def test_current_project_and_mouse_inputs(self):
        self.check(True,'AUX-MOUSE-PROJECT-SOURCE-CONTRACT-OK: exact159defs')
        project = self.flow/'hw/create_project.tcl'; original=project.read_text()
        for name in export.mouse.ADDED:
            for replacement in ('',name+' '+name):
                self.assertEqual(original.count(name),1)
                project.write_text(original.replace(name,replacement))
                self.check(False,'missing or duplicate mouse source')
        project.write_text(original)
        (self.flow/export.mouse.ADDED[0]).unlink() # private disposable test copy only
        self.check(False,'missing mouse RTL file')

    def test_current_strict_x87_mode_cannot_be_dropped(self):
        original=self.defs.read_text();self.assertEqual(original.count('VEN_X87_MF_STRICT\n'),1)
        self.defs.write_text(original.replace('VEN_X87_MF_STRICT\n',''))
        self.check(False,'wrong strict waiting-x87 extension/order')

    def test_uv_and_full_caches_remain_required(self):
        original=self.defs.read_text();self.assertEqual(original.count('VEN_FE_PIPE\n'),1)
        self.defs.write_text(original.replace('VEN_FE_PIPE\n','VEN_CACHE_HALF\n'))
        self.check(False,'VEN_CACHE_HALF is retired')


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--source',type=Path);parser.add_argument('--overlay',type=Path)
    args,remaining=parser.parse_known_args()
    SOURCE=args.source.resolve(strict=True) if args.source else None
    OVERLAY=args.overlay.resolve(strict=True) if args.overlay else None
    unittest.main(argv=[__file__,*remaining])
