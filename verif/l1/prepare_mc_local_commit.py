"""Private successor-owner commit cofactor of FP-WIDE-CONTEXT.

Keep all four public cache-hint commits. A pipeline successor owner cannot
belong to either the AGI or reference-only hint; do not route those commits
back through the pipeline owner's acceptance and register enables.
"""
import hashlib
import re

PARENTS={
    'core_mem_chain.svh':'3630952571613ece5b9845f641f0adfba0fa43cd14f99a72bc5802723e5fbaac',
    'core_agi_resident_prime.svh':'818dbc33998087af6849f5ca3177733f7ab05de38e670b9a6e470e2fe275d092',
    'core_ref_operand_prime.svh':'e4a31829ed91c44ccfdb5e96350c95f3953c8c6d746a97b3b25c094b5be35399',
}


def assignment(source,name):
    rows=re.findall(r'^  assign '+name+r'\s*=.*?;\n',source,re.M|re.S)
    rows=[r for r in rows if "= 1'b0;" not in r]
    if len(rows)!=1:raise ValueError('local-commit equation drift: '+name)
    return rows[0]


def audit_guards(inputs):
    # Pin the complete files, including later assignments and #ifdef branches;
    # these source obligations are not inferred from testbench assumptions.
    for name,digest in PARENTS.items():
        if hashlib.sha256(inputs[name].encode()).hexdigest()!=digest:
            raise ValueError('local-commit source drift: '+name)
    chain=inputs['core_mem_chain.svh']
    assert assignment(chain,'mc_offer').startswith('  assign mc_offer = mc_valid_q &&')
    assert 'mc_prime_base && mc_prepare_ok;' in assignment(chain,'mc_prime_offer')
    assert chain.count('mc_prepare_ok =')==3
    assert 'mc_prepare_ok = !agi_prime_select && !ref_prime_select && mc_boundary_ok &&' in chain
    assert 'mc_prepare_ok = mc_prepare_ok && sys_fp_ok &&' in chain
    assert "mc_prepare_ok = 1'b0;" in chain
    for name,prefix in (('core_agi_resident_prime.svh','agi'),('core_ref_operand_prime.svh','ref')):
        source=inputs[name]
        assert '!mc_valid_q &&' in assignment(source,prefix+'_prime_select')
        assert assignment(source,prefix+'_prime_offer').startswith(
            '  assign '+prefix+'_prime_offer = '+prefix+'_prime_select &&')
        assert assignment(source,prefix+'_prime_commit').startswith(
            '  assign '+prefix+'_prime_commit = '+prefix+'_prime_offer &&')


def edits(source):
    old=assignment(source,'mem_next_commit')
    prefix='  assign mem_next_commit = agi_prime_commit || ref_prime_commit || '
    assert old.startswith(prefix)
    new='''  // AGI/reference-only hints never create a pipeline successor owner.
  // mc_offer has mc_valid_q; their selectors require !mc_valid_q.
  // mc_prime_offer requires !agi_prime_select && !ref_prime_select.
  // Preserve the public OR below, but do not feed unrelated hint completion
  // (including live own-store snoop recovery) back into pipeline owner bits.
  logic mc_pipeline_commit;
  assign mc_pipeline_commit = '''+old[len(prefix):]+'''  assign mem_next_commit = agi_prime_commit || ref_prime_commit || mc_pipeline_commit;
'''
    yield old,new
    for name in ('mc_chain_accept','mc_prime_accept'):
        before=assignment(source,name)
        assert before.count('mem_next_commit')==1
        after=before.replace('mem_next_commit','mc_pipeline_commit')
        witness=name+'_before_local_commit'
        after+='`ifndef SYNTHESIS\n  logic '+witness+';\n'+before.replace(name,witness)+'''
  always_ff @(posedge clk) if (rst_n)
    assert ('''+name+' === '+witness+''')
      else $fatal(1,"MC-LOCAL-COMMIT: '''+name+'''");
`endif
'''
        yield before,after


def transform(inputs):
    audit_guards(inputs)
    source=inputs['core_mem_chain.svh'];result=source
    for old,new in edits(source):
        assert result.count(old)==1
        result=result.replace(old,new)
    return result
