"""Eliminate unreachable retained-successor storage in cache-only RAW mode.

No hint is disabled. In this existing mode prepare implies prime_base, while
the retained capture requires its negation. The non-RAW implementation stays
byte-for-byte unchanged. Simulation retains the original state as a witness.
"""
import hashlib
import re

FILE = 'rtl/core/core_mem_chain.svh'
PARENT = '3615d9ea4bf93e8c3e08958a1459b111f2bff692822d988d24ec9045f05787ca'
STATE = ('mc_valid_q', 'mc_pair_q', 'mc_dirty_q', 'mc_pc_q', 'mc_ea_q',
         'mc_lin_q', 'mc_phys_q', 'mc_seg_q', 'mc_u_q', 'mc_v_q')


def storage(text):
    first = text.index('  always_ff @(posedge clk) begin\n    if (!rst_n) begin\n      mc_valid_q <=')
    last = text.index('\n  end\n', first) + len('\n  end\n')
    return text[first:last]


def check_guard(text):
    if hashlib.sha256(text.encode()).hexdigest() != PARENT:
        raise ValueError('raw-prime storage parent drift/reapplication')
    assert text.count('mc_prepare_ok =') == 3
    assert '''mc_prepare_ok = !agi_prime_select && !ref_prime_select && mc_boundary_ok &&
`ifdef VEN_RAW_V_READ_PRIME
        // Cache-window warmup only; never retain/execute the hint descriptor.
        mc_prime_base &&''' in text
    assert 'mc_prepare_ok = mc_prepare_ok && sys_fp_ok &&' in text
    assert "mc_prepare_ok = 1'b0;" in text
    old = storage(text)
    # Only the reset, clear and guarded capture can assign these registers.
    for name in STATE:
        assert len(re.findall(r'\b'+name+r'\s*<=', text)) == len(re.findall(r'\b'+name+r'\s*<=', old))
    assert old.count('mc_prepare_ok && !mc_prime_base') == 2
    assert 'mc_valid_q <= mc_prepare_ok && !mc_prime_base;' in old
    assert 'if (mc_prepare_ok && !mc_prime_base) begin' in old
    assert old.count("mc_valid_q <= 1'b0;") == 2
    return old


def replacement(text):
    old = check_guard(text)
    renamed = old
    for name in STATE:
        renamed = re.sub(r'\b'+name+r'\b', 'raw_storage_ref_'+name, renamed)
    declarations = '''  logic raw_storage_ref_mc_valid_q, raw_storage_ref_mc_pair_q, raw_storage_ref_mc_dirty_q;
  logic [31:0] raw_storage_ref_mc_pc_q, raw_storage_ref_mc_ea_q;
  logic [31:0] raw_storage_ref_mc_lin_q, raw_storage_ref_mc_phys_q;
  logic [2:0] raw_storage_ref_mc_seg_q;
  fpd_t raw_storage_ref_mc_u_q, raw_storage_ref_mc_v_q;
'''
    constants = ''.join(f"  assign {name} = '0;\n" for name in STATE)
    vector = ', '.join('raw_storage_ref_'+name for name in STATE)
    return '''`ifdef VEN_RAW_V_READ_PRIME
  // RAW hints warm a cache window only. The unchanged preparation equation
  // implies mc_prime_base; retained capture requires !mc_prime_base. All ten
  // registers therefore stay at reset zero. Make that invariant structural
  // instead of retaining a nonexistent successor and its commit/AGU muxes.
  // Live AGI, reference, ordinary/held-V, branch and FP hints are unchanged.
'''+constants+'''`ifndef SYNTHESIS
  // Execute the original state machine in simulation: a future change that
  // admits retained storage in RAW mode must fail, not silently lose an owner.
'''+declarations+renamed+f'''  always_ff @(posedge clk) if (rst_n)
    assert ({{{vector}}} === '0)
      else $fatal(1,"RAW-PRIME-STORAGE: retained owner/payload became reachable");
`endif
`else
'''+old+'''`endif
'''


def transform(text):
    old = check_guard(text)
    assert text.count(old) == 1
    return text.replace(old, replacement(text))
