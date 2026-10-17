import io
from pathlib import Path
import unittest
from unittest.mock import Mock

from audit_clock_eco_netlists import logical_hash
from prepare_programmable_clock_repair import adapt
from audit_clock_reuse import validate as validate_reuse


class RepairTests(unittest.TestCase):
    def test_exact_adapter_boundary(self):
        source=(Path(__file__).parent/'ven_programmable_clock.v').read_text()
        result=adapt(source)
        self.assertIn('input wire [15:0] ps_gpio_o', result)
        self.assertIn('output wire [7:0] ps_gpio_i', result)
        self.assertIn('output wire [5:0] mmcm_reset_reg', result)
        self.assertIn('assign ps_gpio_i = {status[10], status[6:0]}', result)
        self.assertIn('assign mmcm_reset_reg = {status[13:11], status[9:7]}', result)
        self.assertIn('.command_async(ps_gpio_o)', result)
        self.assertEqual(source[source.index('    MMCME4_ADV'):],
                         result[result.index('    MMCME4_ADV'):])
        with self.assertRaises(ValueError): adapt(result)

    def test_boundary_bit_roundtrip(self):
        for low in range(1<<14):
            div_lock=((low>>10)&1)<<7 | (low&127)
            flags=((low>>11)&7)<<3 | ((low>>7)&7)
            restored=((flags>>3)&7)<<11 | ((div_lock>>7)&1)<<10 | (flags&7)<<7 | (div_lock&127)
            self.assertEqual(low, restored)

    def digest(self, data):
        path=Mock()
        path.open.return_value=io.BytesIO(data)
        return logical_hash(path)

    def test_soc_hash_ignores_only_comments_and_blank_lines(self):
        body=b''.join(f'module n{i}; wire x=1; endmodule\n'.encode() for i in range(100))
        self.assertEqual(self.digest(b'// old date\n'+body), self.digest(b'// new date\n\n'+body))
        self.assertNotEqual(self.digest(body),self.digest(body.replace(b'x=1',b'x=0',1)))
        self.assertNotEqual(self.digest(body),self.digest(b'(* INIT="1" *)\n'+body))

    def test_missing_soc_rejected(self):
        with self.assertRaises(ValueError): self.digest(b'module leaf; endmodule\n')

    REUSE='| Cells | 99.96 | 99.97 | 0.01 | 294278 |\n| Nets | 99.97 | 99.91 | 0.00 | 192208 |\n'

    def test_canonical_reuse(self):
        self.assertEqual(validate_reuse(self.REUSE)['Cells']['reused_pct'],99.97)

    def test_missing_duplicate_reuse_rows(self):
        for text in (self.REUSE.splitlines()[0],self.REUSE+self.REUSE):
            with self.subTest(text=text),self.assertRaises(ValueError): validate_reuse(text)

    def test_low_or_impossible_canonical_percent(self):
        for before,after in (('99.96','99.49'),('99.97','0.00'),('99.91','100.01')):
            with self.subTest(after=after),self.assertRaises(ValueError):
                validate_reuse(self.REUSE.replace(before,after))

    def test_missing_design_reuse_totals(self):
        with self.assertRaises(ValueError): validate_reuse(self.REUSE.replace('294278','1'))
        with self.assertRaises(ValueError): validate_reuse(self.REUSE.replace('192208','1'))


if __name__ == '__main__': unittest.main()
