"""Restore saved x87 pointers through existing atomic environment commits.

Four Intel layouts, not a protected-only alias. V86 uses the real format.
Does not implement the separately missing FOP register or change ordinary
FP pointer capture / environment stores / status or tag representation.
"""
import hashlib

PARENTS = {
    'fp_shared/ven_fp_top.sv': 'de65098da526dd472b34ac0b46c664d55ef60617305cc93e7e68fafcf7a92c57',
    'rtl/core/core.sv': '27e3faf2f9d8f6a912748a0443a083f3fa1e50404e5368b7678ac72debec9b42',
}

POINTERS = """    // Intel P5 Vol. 3, figures 6-6 through 6-9. Real/V86 images
    // encode linear pointers, not selectors. Ignore only reserved bits.
    if (cmd_env16) begin
      env_load_fip = {16'd0, cmd_env_image[63:48]};
      env_load_fdp = {16'd0, cmd_env_image[95:80]};
      env_load_fcs = cmd_env_image[79:64];
      env_load_fds = cmd_env_image[111:96];
      if (cmd_real_mode) begin
        env_load_fip = {12'd0, cmd_env_image[79:76], cmd_env_image[63:48]};
        env_load_fdp = {12'd0, cmd_env_image[111:108], cmd_env_image[95:80]};
        env_load_fcs = 16'd0;
        env_load_fds = 16'd0;
      end
    end else begin
      env_load_fip = cmd_env_image[127:96];
      env_load_fdp = cmd_env_image[191:160];
      env_load_fcs = cmd_env_image[143:128];
      env_load_fds = cmd_env_image[207:192];
      if (cmd_real_mode) begin
        env_load_fip = {cmd_env_image[155:140], cmd_env_image[111:96]};
        env_load_fdp = {cmd_env_image[219:204], cmd_env_image[175:160]};
        env_load_fcs = 16'd0;
        env_load_fds = 16'd0;
      end
    end
"""


def transform(source, name):
    if hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('FP environment source drift/reapplication: '+name)
    if name == 'rtl/core/core.sv':
        edits = [('.cmd_real_mode(real_mode), .cmd_env_image(fp_shared_env_image)',
                  '.cmd_real_mode(seg_real), .cmd_env_image(fp_shared_env_image)')]
    else:
        edits = [
            ('  logic [639:0] env_load_regs_phys;\n',
             '  logic [31:0] env_load_fip, env_load_fdp;\n'
             '  logic [15:0] env_load_fcs, env_load_fds;\n'
             '  logic [639:0] env_load_regs_phys;\n'),
            ('    env_load_control = cmd_env_image[15:0];\n',
             POINTERS+'    env_load_control = cmd_env_image[15:0];\n'),
            ('          c_env         = 1\'b1;\n',
             "          // Commit pointers with the fully assembled environment, never\n"
             "          // from the administrative instruction's own command address.\n"
             "          c_eptr        = 1'b1;\n"
             "          c_dptr        = 1'b1;\n"
             "          c_env         = 1'b1;\n"),
        ]
        for port, value in (('eptr_fip','fip'),('eptr_fcs','fcs'),('dptr_fdp','fdp'),('dptr_fds','fds')):
            edits.append(('.'+port+'(cmd_'+value+')',
                          '.'+port+'(c_env ? env_load_'+value+' : cmd_'+value+')'))
    for before, after in edits:
        if source.count(before) != 1:
            raise ValueError('FP environment ambiguous anchor: '+name)
        source = source.replace(before, after)
    return source
