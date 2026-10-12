"""Private AGI/reference-prime cofactor; leave the shared FP permit unchanged.

AGI prevents a new integer request. Reference priming selects a nonsimple
descriptor, which makes fp_sys_bail true and likewise prevents that request.
The x87 => nonsimple decoder invariant is a qualification prerequisite.
This does not replace architectural commit, read ACK, or any fault guard.
"""
import hashlib
import re

HASHES = {
    'rtl/core/core.sv': '8d0c3c35eca0c3ea97981d3f33178ef0c656a2eb90f27faea97fe998ab5e24a0',
    'rtl/core/core_agi_resident_prime.svh': '4f35f4274b5e78e0dd9e4161db24db5b33442a7855e437ec27da9fe9aa3fb479',
    'rtl/core/core_ref_operand_prime.svh': 'b177c0355f020f435b78a7c94c5679454209033f10004427cfda755e20d98c7d',
}


def statement(source, name, prefix='  assign ', starts=''):
    matches = re.findall(re.escape(prefix+name)+r'\s*= '+re.escape(starts)+r'.*?;', source, re.S)
    if len(matches) != 1:
        raise ValueError('ambiguous source equation: '+name)
    return matches[0]


def new_arm(source):
    original = statement(source, 'pipe_fp_live_arm')
    if original.count('!pipe_mem_wait;') != 1:
        raise ValueError('live-arm memory guard drift')
    return original.replace('pipe_fp_live_arm', 'pipe_prime_live_arm').replace(
        '!pipe_mem_wait;', '(pipe_agi || fp_sys_bail);')


def transform(inputs):
    if set(inputs) != set(HASHES):
        raise ValueError('need the complete three-file priming interface')
    for name, digest in HASHES.items():
        if hashlib.sha256(inputs[name].encode()).hexdigest() != digest:
            raise ValueError('priming parent drift/reapplication: '+name)
    result = dict(inputs)
    core = 'rtl/core/core.sv'
    old = statement(result[core], 'pipe_fp_live_arm')
    addition = '''

  // AGI/reference priming only, never an FP-execution or retirement permit.
  // AGI suppresses both new integer requests. A nonsimple reference packet
  // has fp_sys_bail set, suppressing them too. The existing selectors reject
  // an admitted packet; x87 descriptors are nonsimple (checked below and in
  // the decoder regression). Preserve every live/FSM/frontend/stall guard.
  // Unlike the rejected FP-only global cut, integer-memory descriptors may
  // still prime on their paid AGI clock. Do not require !u_d.is_mem here.
  logic pipe_prime_live_arm;
'''+new_arm(result[core])
    result[core] = result[core].replace(old, old+addition)
    for kind in ('agi', 'ref'):
        path = 'rtl/core/core_'+('agi_resident_prime.svh' if kind == 'agi' else 'ref_operand_prime.svh')
        name = kind+'_prime_commit'
        original = statement(result[path], name, starts=kind+'_prime_offer')
        if original.count('pipe_fp_live_arm') != 1:
            raise ValueError('priming consumer drift: '+kind)
        changed = original.replace('pipe_fp_live_arm', 'pipe_prime_live_arm')
        before = kind+'_prime_before_ack_cut'
        witness = '''
`ifndef SYNTHESIS
  logic '''+before+';\n'+original.replace(name, before)+'''
  always_ff @(posedge clk) if (rst_n) begin
    assert ('''+name+' === '+before+''')
      else $fatal(1,"PRIME-NOACK: changed '''+kind+''' commit");
    if ('''+name+''') begin
      assert (!pipe_mem_active_q && !pipe_load_req && !pipe_store_req && !pipe_mem_wait)
        else $fatal(1,"PRIME-NOACK: '''+kind+''' acquired an integer memory owner");
    end
  end
`endif
'''
        result[path] = result[path].replace(original, changed+witness)
    return result
