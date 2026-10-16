import unittest
import build_parallel_write_core as builder


class ParallelWriteCoreBuild(unittest.TestCase):
    def test_resource_floor_and_private_harness(self):
        source=builder.adapted_main()
        self.assertIn('shutil.disk_usage(scratch).free > 10*1024**3',source)
        self.assertIn("'tb_parallel_write_'",source)
        self.assertIn('pass_fds=(9,)',source)
        self.assertIn('len(files) == 195',source)
        self.assertIn('len(definitions) == len(set(definitions)) == 153',source)

    def test_actual_two_file_derivative_and_native_build(self):
        source=builder.adapted_main()
        self.assertIn('recipe.transform({n:',source)
        self.assertIn('assert text == (leaf/Path(n).name).read_text()',source)
        self.assertIn('native.MODEL, native.CHANGES = MODEL, CHANGES',source)
        self.assertIn('return native.build(root)',source)
        self.assertEqual(builder.CHANGES,['rtl/mem/ven_axi_master.sv','rtl/mem/ventium_l1_axi.sv'])
        self.assertEqual(builder.MODEL,'41f99bcff8125a2caa7fe768f03f242bed1a43323e4d3a190109167248a34e9b')


if __name__=='__main__': unittest.main()
