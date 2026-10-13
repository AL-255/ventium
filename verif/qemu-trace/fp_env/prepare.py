"""Private QEMU 8.2.2 x87 environment pointer-codec correction.

Intel P5 Volume 3 figures 6-6..6-9. This does not change arithmetic, tags,
status interpretation, ordinary pointer/opcode capture or translator policy.
"""
import hashlib

SOURCE_SHA = 'efb0daf00682ed65488b6ee606a409da7d84f1bb6c118d1bdbc8d27ead37c4e6'

STORE_BEFORE = """        cpu_stl_data_ra(env, ptr + 12, env->fpip, retaddr); /* fpip */
        cpu_stl_data_ra(env, ptr + 16, env->fpcs, retaddr); /* fpcs */
        cpu_stl_data_ra(env, ptr + 20, env->fpdp, retaddr); /* fpoo */
        cpu_stl_data_ra(env, ptr + 24, env->fpds, retaddr); /* fpos */
"""
STORE_AFTER = """        cpu_stl_data_ra(env, ptr + 12, real_format ? ip & 0xffff : ip, retaddr);
        cpu_stl_data_ra(env, ptr + 16, real_format
                       ? ((ip >> 16) << 12) | (env->fpop & 0x7ff)
                       : env->fpcs | ((env->fpop & 0x7ff) << 16), retaddr);
        cpu_stl_data_ra(env, ptr + 20, real_format ? dp & 0xffff : dp, retaddr);
        cpu_stl_data_ra(env, ptr + 24, real_format
                       ? (dp >> 16) << 12 : env->fpds, retaddr);
"""
STORE16_BEFORE = """        cpu_stw_data_ra(env, ptr + 6, env->fpip, retaddr);
        cpu_stw_data_ra(env, ptr + 8, env->fpcs, retaddr);
        cpu_stw_data_ra(env, ptr + 10, env->fpdp, retaddr);
        cpu_stw_data_ra(env, ptr + 12, env->fpds, retaddr);
"""
STORE16_AFTER = """        cpu_stw_data_ra(env, ptr + 6, ip, retaddr);
        cpu_stw_data_ra(env, ptr + 8, real_format
                       ? ((ip >> 4) & 0xf000) | (env->fpop & 0x7ff)
                       : env->fpcs, retaddr);
        cpu_stw_data_ra(env, ptr + 10, dp, retaddr);
        cpu_stw_data_ra(env, ptr + 12, real_format
                       ? (dp >> 4) & 0xf000 : env->fpds, retaddr);
"""
LOAD_BEFORE = """    int i, fpus, fptag;

    if (data32) {
        cpu_set_fpuc(env, cpu_lduw_data_ra(env, ptr, retaddr));
        fpus = cpu_lduw_data_ra(env, ptr + 4, retaddr);
        fptag = cpu_lduw_data_ra(env, ptr + 8, retaddr);
    } else {
        cpu_set_fpuc(env, cpu_lduw_data_ra(env, ptr, retaddr));
        fpus = cpu_lduw_data_ra(env, ptr + 2, retaddr);
        fptag = cpu_lduw_data_ra(env, ptr + 4, retaddr);
    }
    cpu_set_fpus(env, fpus);
"""
LOAD_AFTER = """    uint32_t image[7], ip, dp;
    uint16_t cs, ds, opcode;
    int i, fpus, fptag;
    bool real_format = !(env->hflags & HF_PE_MASK) || (env->eflags & VM_MASK);

    /* Read the complete operand before changing state. A newly observed
     * pointer-page fault must not leave CW from a partly restored image. */
    for (i = 0; i < 7; i++) {
        image[i] = data32 ? cpu_ldl_data_ra(env, ptr + i * 4, retaddr)
                         : cpu_lduw_data_ra(env, ptr + i * 2, retaddr);
    }
    ip = image[3];
    dp = image[5];
    cs = image[4];
    ds = image[6];
    opcode = data32 ? (image[4] >> 16) & 0x7ff : env->fpop;
    if (real_format) {
        ip = (ip & 0xffff) | (data32 ? ((image[4] >> 12) & 0xffff) << 16
                                            : (image[4] & 0xf000) << 4);
        dp = (dp & 0xffff) | (data32 ? ((image[6] >> 12) & 0xffff) << 16
                                            : (image[6] & 0xf000) << 4);
        /* The real image contains a linear pointer, not a selector. Ordinary
         * translator-produced offset/selector pairs remain separately valid. */
        cs = ds = 0;
        opcode = image[4] & 0x7ff;
    }
    fpus = image[1] & 0xffff;
    fptag = image[2] & 0xffff;
    cpu_set_fpuc(env, image[0] & 0xffff);
    env->fpip = ip;
    env->fpdp = dp;
    env->fpcs = cs;
    env->fpds = ds;
    env->fpop = opcode;
    cpu_set_fpus(env, fpus);
"""


def transform(text):
    if hashlib.sha256(text.encode()).hexdigest() != SOURCE_SHA:
        raise ValueError('QEMU environment parent drift/reapplication')
    edits = [
        ('    CPU_LDoubleU tmp;\n\n    fpus = (env->fpus & ~0x3800)',
         '    CPU_LDoubleU tmp;\n'
         '    bool real_format = !(env->hflags & HF_PE_MASK) || (env->eflags & VM_MASK);\n'
         '    uint32_t ip = env->fpip, dp = env->fpdp;\n\n'
         '    if (real_format) {\n'
         '        ip += (uint32_t)env->fpcs << 4;\n'
         '        dp += (uint32_t)env->fpds << 4;\n'
         '    }\n'
         '    fpus = (env->fpus & ~0x3800)'),
        (STORE_BEFORE, STORE_AFTER), (STORE16_BEFORE, STORE16_AFTER),
        (LOAD_BEFORE, LOAD_AFTER),
    ]
    for before, after in edits:
        if text.count(before) != 1:
            raise ValueError('QEMU environment ambiguous anchor')
        text = text.replace(before, after)
    return text
