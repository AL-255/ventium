"""Remove format conversion from compare-invalid classification, without retiming."""
import hashlib

PARENT = '05bfa2a4d6eb1a3d3911b31a71c7d8ce1ec161d0e60f2408c6ae0061efb77aeb'
ANCHOR = '  // A single shared compare/classify cone feeds every compare opcode.\n'
OLD = 'fcom_ie(st0_data, cmp_b, cmp_signaling)'
NEW = 'compare_invalid(cmd_op, st0_data, sti_data, cmd_mem, cmd_mem_bytes)'
FUNCTION = '''  // Invalid classification needs the source encoding, not normalized data.
  // Every signed integer converts to a finite exact floatx80 value; float32
  // and float64 NaN classes are invariant under the existing widening.
  // Preserve the default floatx80 and quiet/register forms for every size.
  // Numeric condition codes still use the original shared compare datapath.
  function automatic logic compare_invalid(
      input fxop_e op, input logic [79:0] a, input logic [79:0] sti,
      input logic [79:0] memory, input logic [3:0] bytes);
    logic memory_nan;
    unique case (bytes)
      4'd4: memory_nan = (&memory[30:23]) && (|memory[22:0]);
      4'd8: memory_nan = (&memory[62:52]) && (|memory[51:0]);
      default: memory_nan = fx_is_nan(memory);
    endcase
    unique case (op)
      FX_FCOM_M32, FX_FCOM_M64:
        return fx_is_nan(a) || memory_nan;
      FX_FICOM_M16, FX_FICOM_M32, FX_FTST:
        return fx_is_nan(a);
      FX_FUCOM_STI, FX_FUCOMPP:
        return fx_is_snan(a) || fx_is_snan(sti);
      default:
        return fx_is_nan(a) || fx_is_nan(sti);
    endcase
  endfunction

'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('FP compare classifier parent drift')
    assert source.count(ANCHOR) == source.count(OLD) == 1
    changed = source.replace(ANCHOR, FUNCTION+ANCHOR).replace(OLD, NEW)
    assert changed.replace(FUNCTION, '').replace(NEW, OLD) == source
    return changed


def compare_block(source):
    start = source.index(ANCHOR)
    return source[start:source.index('  // Canonical FNSTENV/FNSAVE images.', start)]
