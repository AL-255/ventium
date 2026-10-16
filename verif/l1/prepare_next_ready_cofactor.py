"""Remove late next-request/tag selection from next-read readiness only.

Exact binary identity, not speculative admission. The existing lookup
selection, data ports and sequential response/capture owner remain unchanged.
"""
import hashlib

PARENT='62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3'
FILE='rtl/mem/ven_l1d.sv'
BEGIN='  assign mc_lookup_old = c_next_req && c_req'
END='  assign mc_capture_next = c_next_ready && c_next_commit;\n'


def block(source):
    begin=source.index(BEGIN);end=source.index(END,begin)+len(END)
    return source[begin:end]


def changed_block(source):
    old=block(source)
    new=old.replace('assign mc_lookup_old = c_next_req &&','assign mc_old_slot =',1)
    new=new.replace('assign mc_lookup_prime = c_next_req &&','assign mc_prime_slot =',1)
    new=new.replace("assign mc_lookup_prime = 1'b0;","assign mc_prime_slot = 1'b0;",1)
    anchor='  assign mc_lookup_next = mc_lookup_old || mc_lookup_prime;'
    assert new.count(anchor)==1
    new=new.replace(anchor,
        '  assign mc_lookup_old = c_next_req && mc_old_slot;\n'
        '  assign mc_lookup_prime = c_next_req && mc_prime_slot;\n'+anchor)
    before='''  assign c_next_ready = mc_lookup_next && c_next_cacheable &&
      (mc_lookup_prime || cacheable) &&
      !golden && !flush_all && !snoop_inv_valid && hit &&'''
    after='''  // lookup implies the prime tag result; do not select it through
  // the late request-dependent hit mux. Factor request after the two slot
  // predicates, retaining current cacheability only for the old-read slot.
  assign c_next_ready = c_next_req &&
      (mc_prime_slot || (mc_old_slot && cacheable)) && c_next_cacheable &&
      !golden && !flush_all && !snoop_inv_valid && (|tag_prime_hit) &&'''
    assert new.count(before)==1
    return '  logic mc_old_slot, mc_prime_slot;\n'+new.replace(before,after)


def transform(source):
    assert hashlib.sha256(source.encode()).hexdigest()==PARENT
    old=block(source);new=changed_block(source)
    ready=old[old.index('  assign c_next_ready ='):old.index('  assign mc_capture_next =')]
    witness='''`ifndef SYNTHESIS
  logic c_next_ready_before_cofactor;
'''+ready.replace('assign c_next_ready =','assign c_next_ready_before_cofactor =')+'''
  always_ff @(posedge clk) if (rst_n)
    assert (c_next_ready === c_next_ready_before_cofactor)
      else $fatal(1,"NEXT-READY-COFACTOR: readiness changed");
`endif
'''
    assert source.count(old)==1
    return source.replace(old,new+witness)
