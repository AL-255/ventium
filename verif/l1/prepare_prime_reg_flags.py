"""Isolated register-only flag cofactor for branch next-read COMMIT.

The global execution ALU, branch resolution, request/admission and ownership
are unchanged. Only this non-memory branch consumer gets a flags-only copy;
its shifter outputs are disconnected and the existing register shifter is
shared. Full-core equivalence and area/timing measurements remain required.
"""
import hashlib
import re

PARENTS = {
    'core.sv':'8dc1180b154b99b7fdf586071ca53d72427f09648403cf8f0120a4f570e3ed8d',
    'core_mem_chain.svh':'b1e94ba311c54860a56d872aadaff75771c6eff795bb112f2bc0476b3ec29788',
    'u_pipe.sv':'a93bbe5f4a29df896fd4be1d92807889030d432ab6bb1ef6d1b9b7712e5ff222',
    'uv_common.sv':'fb639f2be09a400739b3c82f39c00d712ed550d18eee6d2533bf0f2b57c4d377',
    'ventium_alu_pkg.sv':'d99bb02a29042157b87b7cb0451d7aa6c6e3751873fd7674b5a040e01f5d1156',
    'ventium_decode_pkg.sv':'19254cb2efe8f5338838494a70ef2a270a025f4f684e87ebb0c071b41e9bf1f7',
}
ADDED = '''  // A V-branch prime requires a register-only U instruction. Prepare
  // its flags from the already lane-selected GPR operands, without importing
  // the unrelated memory-response mux into next-read capture qualification.
  // The execution ALU and actual branch/retirement consumers stay unchanged.
  // Only flags are observable from this copy; no second shifter is connected.
  logic [31:0] mc_reg_u_flags, mc_reg_branch_flags;
  logic mc_reg_v_br_taken;
  u_pipe u_mc_reg_branch_flags (
    .u_d(pipe_u_eff), .u_dst_val(u_dst_reg_val), .u_src_val(u_src_reg_val),
    .eflags(eflags), .u_alu(), .u_flags(mc_reg_u_flags),
    .u_sh(), .u_shm1(), .u_shcf(), .u_shcnt()
  );
  always_comb begin
    mc_reg_branch_flags = pipe_u_eff.wflags ? mc_reg_u_flags : eflags;
    if (pipe_u_eff.is_shift)
      mc_reg_branch_flags = fast_shift_flags(pipe_u_eff.shrot, pipe_u_eff.shimm,
          u_sh, u_shm1, u_shcf, eflags, fp_operand_width(pipe_u_eff));
    mc_reg_v_br_taken = pipe_v_eff.br_cond
                     ? cond_true(pipe_v_eff.cc, mc_reg_branch_flags) : 1'b1;
  end

'''


def commit(source):
    rows = re.findall(r'^  assign mc_pipeline_commit =.*?;\n',source,re.M|re.S)
    if len(rows)!=1 or rows[0].count('v_br_taken_eff')!=1:
        raise ValueError('prime branch commit anchor drift')
    return rows[0]


def transform(sources):
    for name,expected in PARENTS.items():
        if hashlib.sha256(sources[name].encode()).hexdigest()!=expected:
            raise ValueError('prime register flags source drift or reapplication: '+name)
    text=sources['core_mem_chain.svh']
    old=commit(text)
    new=old.replace('v_br_taken_eff','mc_reg_v_br_taken')
    before='  logic mc_pipeline_commit;\n'
    assert text.count(before)==1
    monitor='''`ifndef SYNTHESIS
  logic mc_pipeline_commit_before_reg_flags;
'''+old.replace('mc_pipeline_commit','mc_pipeline_commit_before_reg_flags',1)+'''
  longint unsigned mc_reg_prime_offers, mc_reg_prime_commits, mc_reg_prime_rejects;
  longint unsigned mc_reg_prime_alu, mc_reg_prime_shift, mc_reg_prime_preserve;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mc_reg_prime_offers <= 0; mc_reg_prime_commits <= 0; mc_reg_prime_rejects <= 0;
      mc_reg_prime_alu <= 0; mc_reg_prime_shift <= 0; mc_reg_prime_preserve <= 0;
    end else begin
      assert (mc_pipeline_commit === mc_pipeline_commit_before_reg_flags)
        else $fatal(1,"PRIME-REG-FLAGS: complete pipeline hint commit changed");
      if (mc_prime_v_branch)
        assert (mc_reg_v_br_taken === v_br_taken_eff)
          else $fatal(1,"PRIME-REG-FLAGS: non-memory branch outcome changed");
      if (mc_prime_offer && mc_prime_v_branch && mc_readonly_int_commit) begin
        mc_reg_prime_offers <= mc_reg_prime_offers + 1;
        if (mc_pipeline_commit) mc_reg_prime_commits <= mc_reg_prime_commits + 1;
        else mc_reg_prime_rejects <= mc_reg_prime_rejects + 1;
        if (pipe_u_eff.is_shift) mc_reg_prime_shift <= mc_reg_prime_shift + 1;
        else if (pipe_u_eff.wflags) mc_reg_prime_alu <= mc_reg_prime_alu + 1;
        else mc_reg_prime_preserve <= mc_reg_prime_preserve + 1;
      end
    end
  end
  final $display("PRIME-REG-FLAGS offers=%0d commits=%0d rejects=%0d alu=%0d shift=%0d preserve=%0d",
      mc_reg_prime_offers,mc_reg_prime_commits,mc_reg_prime_rejects,
      mc_reg_prime_alu,mc_reg_prime_shift,mc_reg_prime_preserve);
`endif
'''
    return text.replace(before,ADDED+before).replace(old,new+monitor,1)
