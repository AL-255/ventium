import unittest
from pathlib import Path
from prepare_inactive_l1_settle import prepare


class InactiveL1Profile(unittest.TestCase):
    def test_keeps_runtime_restrictions_and_edge_evaluations(self):
        source=(Path(__file__).resolve().parents[1]/'verif/tb/tb_main.cpp').read_text()
        result=prepare(source)
        self.assertIn('|| defined(VEN_KV260_SOC)',result)
        self.assertIn('require_inactive_l1_settle(*top)',result)
        self.assertIn('inactive_board_settle_environment(environ)',result)
        self.assertEqual(source.count('++mandatory_edge_evals'),result.count('++mandatory_edge_evals'))
        start=source.index('        if (args.system || args.cosim')
        end=source.index('    // Do this after parsing')
        self.assertIn(source[start:end],result)

    def test_refuses_prepared_source(self):
        source=(Path(__file__).resolve().parents[1]/'verif/tb/tb_main.cpp').read_text()
        with self.assertRaises(ValueError):prepare(prepare(source))


if __name__=='__main__':unittest.main()
