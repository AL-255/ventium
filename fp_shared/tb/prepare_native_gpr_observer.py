"""Extend the pinned passive native observer without mutating older receipts.

Read real integer registers alongside x87 state. PTRACE_O_TRACEEXIT supplies
an actual live stop for a target exit INT and is explicitly recorded; it does
not fabricate a post-exit register packet. No guest or register writes.
"""


def transform(source):
    def replace(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise ValueError('missing, ambiguous or already extended native observer')
        source = source.replace(old, new)

    replace('int main(int argc, char **argv)\n', '''static void dump_gpr(const char *label, const struct user_regs_struct *r)
{
    printf("\\\"%s\\\":{", label);
#define GPR(name, member) printf("\\\"" name "\\\":\\\"0x%08x\\\",", (unsigned)(uint32_t)r->member)
    GPR("eax", rax); GPR("ebx", rbx); GPR("ecx", rcx); GPR("edx", rdx);
    GPR("esi", rsi); GPR("edi", rdi); GPR("ebp", rbp); GPR("esp", rsp);
    GPR("eip", rip);
#undef GPR
    printf("\\\"eflags\\\":\\\"0x%08x\\\"}", (unsigned)(uint32_t)r->eflags);
}

int main(int argc, char **argv)
''')
    replace('(void *)(uintptr_t)PTRACE_O_EXITKILL',
            '(void *)(uintptr_t)(PTRACE_O_EXITKILL | PTRACE_O_TRACEEXIT)')
    replace('        struct user_regs_struct regs;',
            '        struct user_regs_struct regs, after_regs;')
    replace('        request(PTRACE_GETFPREGS, &after);\n',
            '        int target_exit_event = ((unsigned)status >> 16) == PTRACE_EVENT_EXIT;\n'
            '        request(PTRACE_GETREGS, &after_regs);\n'
            '        request(PTRACE_GETFPREGS, &after);\n')
    replace('        status = wait_child();\n        if (!WIFEXITED(status)',
            '        status = wait_child();\n'
            '        if (WIFSTOPPED(status) && WSTOPSIG(status) == SIGTRAP &&\n'
            '            ((unsigned)status >> 16) == PTRACE_EVENT_EXIT) {\n'
            '            request(PTRACE_CONT, NULL);\n'
            '            status = wait_child();\n'
            '        }\n'
            '        if (!WIFEXITED(status)')
    replace('        dump_fp("before", &before);',
            '        printf("\\\"target_exit_event\\\":%s,", target_exit_event ? "true" : "false");\n'
            '        dump_gpr("gprs_before", &regs);\n'
            '        printf(",");\n'
            '        dump_gpr("gprs_after", &after_regs);\n'
            '        printf(",");\n'
            '        dump_fp("before", &before);')
    return source
