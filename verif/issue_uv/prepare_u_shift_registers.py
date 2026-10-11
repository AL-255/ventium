"""Isolate the fast U shifter from memory ALU response selection.

Exact source recipe for the measured timing lineage, not a new admission rule.
Fast shift descriptors are register-only; memory shifts retain the sequencer.
"""
import hashlib
import re

PARENT = '920a2ec12f6f1fab6f7368249ee03169298fe76b643380db330cf424192ac541'
BEGIN = '  // ---- U-pipe datapath (core/u_pipe.sv, R3)'
END = '  // ---- V-pipe datapath (core/v_pipe.sv, R3)'
OLD_OPERANDS = '''  logic [31:0] u_dst_val, u_src_val;
  assign u_dst_val = (pipe_u_eff.is_mem && !pipe_u_eff.is_load && !pipe_u_eff.is_store && pipe_u_eff.mem_lhs)
                   ? mem_rdata : reg_read(pipe_u_eff.dst, pipe_u_eff.w8 ? 3'd1 : 3'd4, pipe_u_eff.dst_hi8);
  assign u_src_val = (pipe_u_eff.is_mem && !pipe_u_eff.is_load && !pipe_u_eff.is_store && !pipe_u_eff.mem_lhs)
                   ? mem_rdata : reg_read(pipe_u_eff.src, pipe_u_eff.w8 ? 3'd1 : 3'd4, pipe_u_eff.src_hi8);
'''
NEW_OPERANDS = '''  logic [31:0] u_dst_val, u_src_val, u_dst_reg_val, u_src_reg_val;
  assign u_dst_reg_val = reg_read(pipe_u_eff.dst, pipe_u_eff.w8 ? 3'd1 : 3'd4, pipe_u_eff.dst_hi8);
  assign u_src_reg_val = reg_read(pipe_u_eff.src, pipe_u_eff.w8 ? 3'd1 : 3'd4, pipe_u_eff.src_hi8);
  assign u_dst_val = (pipe_u_eff.is_mem && !pipe_u_eff.is_load && !pipe_u_eff.is_store && pipe_u_eff.mem_lhs)
                   ? mem_rdata : u_dst_reg_val;
  assign u_src_val = (pipe_u_eff.is_mem && !pipe_u_eff.is_load && !pipe_u_eff.is_store && !pipe_u_eff.mem_lhs)
                   ? mem_rdata : u_src_reg_val;
'''
OLD_OUTPUTS = '''    .u_sh      (u_sh),
    .u_shm1    (u_shm1),
    .u_shcf    (u_shcf),
    .u_shcnt   (u_shift_cnt)
  );
'''
NEW_OUTPUTS = '''    .u_sh      (),
    .u_shm1    (),
    .u_shcf    (),
    .u_shcnt   ()
  );

  // The fast decoder admits register shifts only. Do not route the memory
  // ALU response through this shifter and its U-to-V branch flag forwarding.
  // Memory ALU operands above are unchanged; memory shifts still use S_EXEC.
  // Keep u_pipe's general interface for standalone users. Its disconnected
  // shift outputs are dead logic; the core has one observable fast shifter.
  // Preserve high-byte extraction, width masking, CL and zero-count shm1.
  always_comb begin
    u_shift_cnt = pipe_u_eff.shift_cl ? u_src_reg_val[4:0] : pipe_u_eff.shimm;
    u_sh = shrot_result(pipe_u_eff.shrot,
        wmask(u_dst_reg_val, fp_operand_width(pipe_u_eff)),
        {1'b0,u_shift_cnt}, eflags[0], fp_operand_width(pipe_u_eff));
    u_shm1 = (u_shift_cnt==5'd0) ? u_dst_reg_val
        : shrot_result(pipe_u_eff.shrot, u_dst_reg_val,
            {1'b0,u_shift_cnt}-6'd1, eflags[0], fp_operand_width(pipe_u_eff));
    u_shcf = shrot_cf(pipe_u_eff.shrot,
        wmask(u_dst_reg_val, fp_operand_width(pipe_u_eff)),
        {1'b0,u_shift_cnt}, eflags[0], fp_operand_width(pipe_u_eff));
  end
'''
ASSERTION = '''  // Fast-shift operand isolation relies on this decoder/held-owner contract.
  // This is a verification assertion, never a new synthesis admission gate.
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && state == S_PIPE && pipe_u_eff.is_shift)
      assert (!pipe_u_eff.is_mem && !pipe_u_eff.is_load && !pipe_u_eff.is_store)
        else $fatal(1, "U-SHIFT-REGISTER-OWNER: memory descriptor reached fast shifter");
  end
`endif

'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('U shift source parent drift')
    changed = source
    edits = ((OLD_OPERANDS, NEW_OPERANDS), (OLD_OUTPUTS, NEW_OUTPUTS), (END, ASSERTION+END))
    for old, new in edits:
        if changed.count(old) != 1:
            raise ValueError('U shift source anchor drift')
        changed = changed.replace(old, new)
    recovered = changed
    for old, new in reversed(edits):
        recovered = recovered.replace(new, old, 1)
    if recovered != source:
        raise ValueError('U shift non-reversible edit')
    return changed


def extract(source, name):
    """Native leaf uses the actual core operand block and register-read helper."""
    block = source[source.index(BEGIN):source.index(END)]
    block = block.replace(ASSERTION, '')  # sequential invariant is tested in core
    helper = re.search(r'  function automatic logic \[31:0\] reg_read\(.*?  endfunction',
                       source, re.S)
    if helper is None:
        raise ValueError('reg_read extraction drift')
    return f'''module {name}
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
(
  input fpd_t pipe_u_eff,
  input logic [31:0] gpr_o [0:7],
  input logic [31:0] mem_rdata, eflags,
  output logic [31:0] u_alu, u_flags, u_sh, u_shm1,
  output logic u_shcf,
  output logic [4:0] u_shift_cnt
);
{helper.group(0)}
{block}
endmodule
'''
