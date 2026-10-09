#!/usr/bin/env python3
"""Share the six mutually exclusive trans normalizers in a private source copy.

No extra state or clocks: mux operands before the unchanged arithmetic function,
at precisely the original consuming states. Keep production RTL untouched until
sequential A/B, independent arithmetic and hardware cost are qualified.
"""
import argparse
import hashlib
import json
from pathlib import Path


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'expected one source anchor: {old!r}')
    return text.replace(old, new)


def prepare(text):
    calls = (
        "normalize_round_pack(f2_sign_q, f2_exp_q,\n"
        "                                          f2_sig0_q, f2_sig1_q | 64'd1,\n"
        "                                          rc_q)",
        "normalize_round_pack(\n"
        "              1'b0, at_x_exp_q + 32'sd3,\n"
        "              at_x_sig0_q, at_x_sig1_q, 2'd0)",
        "normalize_round_pack(at_result_sign_q, at_result_exp_q,\n"
        "                                          at_result_sig0_q,\n"
        "                                          at_result_sig1_q | 64'd1, rc_q)",
        "normalize_round_pack(fy_result_sign_q ^ fy_y_sign_q,\n"
        "                                          fy_result_exp_q,\n"
        "                                          fy_result_sig0_q,\n"
        "                                          fy_result_sig1_q,\n"
        "                                          rc_q)",
        "normalize_round_pack(\n"
        "                  1'b0, fy_t_exp_q + fy_t_exp_q - 32'sd16382,\n"
        "                  wide_product[255:192], wide_product[191:128], 2'd0)",
        "normalize_round_pack(\n"
        "                  1'b0, at_z_exp_q + at_z_exp_q - 32'sd16382,\n"
        "                  wide_product[255:192], wide_product[191:128], 2'd0)",
    )
    for call in calls:
        text = once(text, call, 'shared_pack_result')
    text = once(text, '  assign busy = (state != T_IDLE);', '''  // All six pack users occupy disjoint sequencer states/continuations.
  // Select before normalization rather than replicating its 128-bit shift,
  // leading-zero count and rounding incrementer at every destination mux.
  logic shared_pack_sign;
  logic signed [31:0] shared_pack_exponent;
  logic [63:0] shared_pack_high, shared_pack_low;
  logic [1:0] shared_pack_rc;
  logic [79:0] shared_pack_result;
  always_comb begin
    shared_pack_sign = 1'b0;
    shared_pack_exponent = 32'sd0;
    shared_pack_high = 64'd0;
    shared_pack_low = 64'd0;
    shared_pack_rc = 2'd0;
    unique case (state)
      T_F2_PACK: begin
        shared_pack_sign = f2_sign_q;
        shared_pack_exponent = f2_exp_q;
        shared_pack_high = f2_sig0_q;
        shared_pack_low = f2_sig1_q | 64'd1;
        shared_pack_rc = rc_q;
      end
      T_ATAN_SPLIT: begin
        shared_pack_exponent = at_x_exp_q + 32'sd3;
        shared_pack_high = at_x_sig0_q;
        shared_pack_low = at_x_sig1_q;
      end
      T_ATAN_PACK: begin
        shared_pack_sign = at_result_sign_q;
        shared_pack_exponent = at_result_exp_q;
        shared_pack_high = at_result_sig0_q;
        shared_pack_low = at_result_sig1_q | 64'd1;
        shared_pack_rc = rc_q;
      end
      T_FY_PACK: begin
        shared_pack_sign = fy_result_sign_q ^ fy_y_sign_q;
        shared_pack_exponent = fy_result_exp_q;
        shared_pack_high = fy_result_sig0_q;
        shared_pack_low = fy_result_sig1_q;
        shared_pack_rc = rc_q;
      end
      T_WIDE_RESULT: begin
        shared_pack_high = wide_product[255:192];
        shared_pack_low = wide_product[191:128];
        unique case (wide_cont_q)
          WIDE_FY_T2:
            shared_pack_exponent = fy_t_exp_q + fy_t_exp_q - 32'sd16382;
          WIDE_ATAN_Z2:
            shared_pack_exponent = at_z_exp_q + at_z_exp_q - 32'sd16382;
          default: ; // No pack consumer in the other wide continuations.
        endcase
      end
      default: ;
    endcase
    shared_pack_result = normalize_round_pack(shared_pack_sign,
        shared_pack_exponent, shared_pack_high, shared_pack_low, shared_pack_rc);
  end

  assign busy = (state != T_IDLE);''')
    assert text.count('normalize_round_pack(') == 2  # definition plus one use
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.out.resolve()
    original = source.read_text()
    candidate = prepare(original)
    output.mkdir(exist_ok=False)
    (output/'ven_fp_trans.sv').write_text(candidate)
    (output/'ven_fp_trans_control.sv').write_text(once(original,
        'module ven_fp_trans\n', 'module ven_fp_trans_control\n'))
    pins = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (source, Path(__file__).resolve(), output/'ven_fp_trans.sv',
                      output/'ven_fp_trans_control.sv')}
    (output/'inputs.json').write_text(json.dumps(pins, indent=2)+'\n')


if __name__ == '__main__':
    main()
