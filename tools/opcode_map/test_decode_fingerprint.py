#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Host-only decoder fingerprint mutations; never build or launch a model."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("opcode_map_under_test", HERE / "gen_opcode_map.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

CORE = """module core;
always_comb begin
  case (op0)
    8'h90: begin d_kind=K_ALU; d_is_nop=1'b1; end
    8'hD9: begin d_fxop=FX_FLD; d_sysop=SYS_LAR; end
    default: d_unknown=1'b1;
  endcase
end
endmodule
"""
PKG = "package decode_pkg; typedef enum {FX_NONE, FX_FLD} fxop_e; endpackage\n"
DECODER = """`default_nettype wire
module decode_stages;
always_comb begin
  d_len=4'd0;
  case (op1)
    8'h00: begin
      if (sys_mode && !seg_real) begin
        d_sysop=(modrm_reg==3'd4) ? SYS_VERR : SYS_VERW;
        d_w=eff_opsize ? 3'd2 : 3'd4;
      end
    end
    default: d_unknown=1'b1;
  endcase
end
endmodule
"""


class DecodeFingerprintTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ventium-opcode-fingerprint-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.core = self.root / "core.sv"
        self.pkg = self.root / "decode_pkg.sv"
        self.decoder = self.root / "decode_stages.sv"
        self.data = self.root / "coverage_data.json"
        self.rst = self.root / "never-written.rst"
        for path, value in ((self.core, CORE), (self.pkg, PKG), (self.decoder, DECODER)):
            path.write_text(value)
        paths = mock.patch.multiple(gen, CORE=str(self.core), PKG=str(self.pkg),
                                    DECODER=str(self.decoder), DATA=str(self.data), RST=str(self.rst))
        paths.start()
        self.addCleanup(paths.stop)
        self.initial = gen.decode_fingerprint()

    def changed_decoder(self, source):
        self.decoder.write_text(source)
        self.assertNotEqual(self.initial, gen.decode_fingerprint())

    def test_opcode_change_and_added_arm_drift(self):
        self.changed_decoder(DECODER.replace("8'h00:", "8'h01:"))
        self.changed_decoder(DECODER.replace("default:", "8'h02: d_sysop=SYS_LAR;\n    default:"))

    def test_mode_predicate_change_drift(self):
        self.changed_decoder(DECODER.replace("sys_mode && !seg_real", "sys_mode || !seg_real"))

    def test_ternary_sysop_change_drift(self):
        self.changed_decoder(DECODER.replace("? SYS_VERR : SYS_VERW", "? SYS_VERW : SYS_VERR"))

    def test_width_and_literal_change_drift(self):
        self.changed_decoder(DECODER.replace("3'd2", "3'd1"))
        self.changed_decoder(DECODER.replace("8'h00", "16'h00"))
        self.changed_decoder(DECODER.replace("modrm_reg==3'd4", "modrm_reg==3'd5"))

    def test_comments_and_formatting_do_not_drift(self):
        formatted = DECODER.replace("sys_mode && !seg_real", "sys_mode\n && /* mode note */ ! seg_real")
        formatted = formatted.replace("d_len=4'd0;", "d_len /* fake 8'hFE: SYS_GARBAGE */ = 4 'd0 ;")
        formatted = "// license changed; d_unknown=1'b1\n" + formatted + "/* trailing note */\n"
        self.decoder.write_text(formatted)
        self.core.write_text(CORE + "// 8'hFF: d_fxop=FX_FAKE;\n")
        self.pkg.write_text(PKG + "/* FX_PHANTOM */\n")
        self.assertEqual(self.initial, gen.decode_fingerprint())

    def test_string_comment_markers_are_executable_literal_contents(self):
        original = DECODER.replace("d_len=4'd0;", r'''d_len=4'd0; $display("/* not a comment */ // text \\\" quoted");''')
        self.decoder.write_text(original)
        before = gen.decode_fingerprint()
        self.decoder.write_text(original.replace("not a comment", "different literal"))
        self.assertNotEqual(before, gen.decode_fingerprint())
        self.decoder.write_text(original + "// external harmless comment\n")
        self.assertEqual(before, gen.decode_fingerprint())

    def test_string_contents_cannot_fake_legacy_signal_checks(self):
        self.core.write_text(CORE + '''initial $display("8'hF1: d_sysop=SYS_FAKE FX_FAKE");\n''')
        self.pkg.write_text(PKG + '''initial $display("FX_FAKE");\n''')
        self.assertEqual(self.initial, gen.decode_fingerprint())

    def test_escaped_identifier_keeps_embedded_comment_markers(self):
        one = gen._sv_tokens("logic \\field//literal ; // real comment\n")
        self.assertEqual(one, ["logic", "\\field//literal", ";"])
        self.assertNotEqual(one, gen._sv_tokens("logic \\field//changed ;\n"))

    def test_operator_boundaries_and_reordering_remain_visible(self):
        self.assertNotEqual(gen._sv_tokens("a + + b"), gen._sv_tokens("a ++ b"))
        self.changed_decoder(DECODER.replace("? SYS_VERR : SYS_VERW", "? SYS_VERW : SYS_VERR"))

    def test_directive_eol_is_semantic_but_continuation_format_is_not(self):
        self.assertNotEqual(gen._sv_tokens("`define VALUE 1\nx=VALUE;\n"),
                            gen._sv_tokens("`define VALUE 1 x=VALUE;\n"))
        self.assertEqual(gen._sv_tokens("`define VALUE a + b\n"),
                         gen._sv_tokens("`define VALUE a \\\n + b\n"))

    def test_numeric_width_cannot_swallow_directive_newline(self):
        self.assertNotEqual(gen._sv_tokens("`define M 8\n'h1\n"),
                            gen._sv_tokens("`define M 8'h1\n"))

    def test_numeric_radix_cannot_swallow_directive_newline(self):
        self.assertNotEqual(gen._sv_tokens("`define M 'h\n1\n"),
                            gen._sv_tokens("`define M 'h1\n"))

    def test_remaining_standard_line_directives_keep_boundaries(self):
        for name in ("unconnected_drive", "nounconnected_drive", "pragma"):
            with self.subTest(name=name):
                self.assertNotEqual(gen._sv_tokens(f"`{name} value\nx=1;\n"),
                                    gen._sv_tokens(f"`{name} value x=1;\n"))

    def test_original_core_and_pkg_checks_still_detect_changes(self):
        self.core.write_text(CORE.replace("K_ALU", "K_SHIFT"))
        self.assertNotEqual(self.initial, gen.decode_fingerprint())
        self.core.write_text(CORE)
        self.pkg.write_text(PKG.replace("FX_FLD", "FX_OTHER"))
        self.assertNotEqual(self.initial, gen.decode_fingerprint())

    def test_missing_and_empty_decoder_fail_closed(self):
        self.decoder.unlink()
        with self.assertRaises(FileNotFoundError):
            gen.decode_fingerprint()
        problems = gen.verify_rtl({"primary": {}, "secondary": {}, "_decode_fingerprint": self.initial})
        self.assertEqual(len(problems), 1)
        self.assertIn("cannot fingerprint", problems[0])
        self.decoder.write_text("// absent implementation\n")
        with self.assertRaisesRegex(ValueError, "no executable tokens"):
            gen.decode_fingerprint()

    def test_malformed_comments_and_strings_fail_closed(self):
        for source in ('module decode_stages; /* unfinished', 'module decode_stages; $display("unfinished'):
            with self.subTest(source=source):
                self.decoder.write_text(source)
                problems = gen.verify_rtl({"primary": {}, "secondary": {}})
                self.assertIn("cannot fingerprint", problems[0])

    def run_verify_cli(self):
        output = io.StringIO()
        with mock.patch.object(gen.sys, "argv", [str(HERE / "gen_opcode_map.py"), "--verify-rtl"]):
            with contextlib.redirect_stderr(output):
                status = gen.main()
        self.assertFalse(self.rst.exists())
        return status, output.getvalue()

    def test_verify_rtl_cli_rejects_stale_fingerprint_and_accepts_current(self):
        self.data.write_text(json.dumps({"primary": {}, "secondary": {}, "_decode_fingerprint": self.initial}))
        self.assertEqual(self.run_verify_cli()[0], 0)
        self.decoder.write_text(DECODER.replace("SYS_VERW", "SYS_LSL"))
        status, stderr = self.run_verify_cli()
        self.assertEqual(status, 1)
        self.assertIn("decoder STRUCTURE changed", stderr)
        self.assertIn("decode_stages.sv", stderr)

    def test_verify_rtl_cli_missing_decoder_is_not_a_pass(self):
        self.data.write_text(json.dumps({"primary": {}, "secondary": {}, "_decode_fingerprint": self.initial}))
        self.decoder.unlink()
        status, stderr = self.run_verify_cli()
        self.assertEqual(status, 1)
        self.assertIn("cannot fingerprint", stderr)


if __name__ == "__main__":
    unittest.main()
