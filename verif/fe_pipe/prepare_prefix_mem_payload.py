"""Separate raw memory metadata from register-only PREFIX66 admission.

Private exact-source experiment. Its decoder invariant must be checked before
any whole-core transfer: an admitted prefixed register descriptor has zero
address metadata. No instruction is newly admitted and no extra cycle is added.
"""
import hashlib

FILE = 'rtl/core/core_prefix66_decode.svh'
DECODER_FILE = 'rtl/core/decode.sv'
PARENT = '73c24c9f7252252203701e7a7872b735a781df020006db2cdf9750dee5a2f116'
DECODER = 'd1eacb527bb88e22e3501159479adc851bb32e234e74f21848446f6cddcfc929'
GUARDED = ('w8', 'is_mem', 'is_store', 'is_stack', 'is_lea',
           'is_branch', 'is_fp', 'shift_cl')
METADATA = ('is_load', 'is_moffs', 'base', 'mem_base_en', 'mem_index',
            'mem_index_en', 'mem_disp', 'mem_scale', 'mem_ss', 'mem_lhs', 'addr_mask')
COMMENT = '''  // PREFIX66 admits register-only operations. Its length/context predicate
  // must not qualify the ordinary memory address fields: that puts a late
  // register-admission cone before the AGU and the cache request/ACK path.
  // These fields are already zero for every admitted prefixed descriptor;
  // the exact decoder/prefix full-payload miter verifies that invariant.
  // Preserve all other fields and the original candidate/D1 policy above.
'''


def sha_text(source):
    return hashlib.sha256(source.encode()).hexdigest()


def suffix():
    return COMMENT + ''.join(
        f"  u_d.{field} = p54_prefix66_shift ? '0 : p54_prefix66_base.{field};\n"
        for field in GUARDED + METADATA)


def transform(source, decoder):
    if sha_text(source) != PARENT or sha_text(decoder) != DECODER:
        raise ValueError('prefix/decoder source drift or reapplication')
    if not source.endswith('  end\nend\n'):
        raise ValueError('prefix output block drift')
    for field in GUARDED:
        if '!p54_prefix66_base.' + field not in source:
            raise ValueError('prefix admission no longer rejects ' + field)
    return source[:-4] + suffix() + 'end\n'


def flag_identity_smt(mutant=False):
    """Unconstrained one-bit cofactor; metadata needs the actual decoder gate."""
    return '''(set-logic QF_UF)
(declare-const shift Bool)
(declare-const remaining_admission Bool)
(declare-const field Bool)
(define-fun candidate () Bool (and shift remaining_admission (not field)))
(define-fun old () Bool (ite shift (ite candidate field false) field))
(define-fun new () Bool ''' + ('(and shift field)' if mutant else '(and (not shift) field)') + ''')
(assert (not (= old new)))
(check-sat)
'''
