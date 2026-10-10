/* Passive native-x87 witness for an unmodified 32-bit ELF. Not a P54 timing
 * oracle, RTL acceptance run, or replacement for the differential gate.
 * No register/memory writes, breakpoints, or injected guest instructions. */
#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/types.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t child = -1;

static _Noreturn void fail(const char *what)
{
    int saved = errno;
    if (child > 0) {
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    }
    fprintf(stderr, "%s: %s\n", what, strerror(saved));
    exit(1);
}

static void request(enum __ptrace_request op, void *data)
{
    if (ptrace(op, child, NULL, data) == -1) fail("ptrace");
}

static int wait_child(void)
{
    int status;
    pid_t got;
    do { got = waitpid(child, &status, 0); } while (got < 0 && errno == EINTR);
    if (got != child) fail("waitpid");
    if (WIFEXITED(status) || WIFSIGNALED(status)) child = -1;
    return status;
}

static void stop_required(int status)
{
    if (!WIFSTOPPED(status) || WSTOPSIG(status) != SIGTRAP) {
        errno = EPROTO;
        fail("expected native SIGTRAP stop");
    }
}

static void dump_fp(const char *label, const struct user_fpregs_struct *fp)
{
    const unsigned char *st = (const unsigned char *)fp->st_space;
    printf("\"%s\":{\"fctrl\":\"0x%04x\",\"fstat\":\"0x%04x\","
           "\"fxsave_tag\":\"0x%02x\",\"st\":[", label,
           fp->cwd, fp->swd, fp->ftw & 255);
    for (int r = 0; r < 8; ++r) {
        printf("%s\"", r ? "," : "");
        for (int b = 9; b >= 0; --b) printf("%02x", st[16*r+b]);
        printf("\"");
    }
    printf("]}");
}

int main(int argc, char **argv)
{
    if (argc != 4 && argc != 5) {
        fprintf(stderr, "usage: %s ELF32 PC OCCURRENCE(1-based) [OPERAND64_ADDR]\n", argv[0]);
        return 2;
    }
    char *end;
    unsigned long pc = strtoul(argv[2], &end, 0);
    if (*end || !pc || pc > UINT32_MAX) return 2;
    unsigned long occurrence = strtoul(argv[3], &end, 0);
    if (*end || !occurrence || occurrence > 100000) return 2;
    unsigned long operand_addr = 0;
    if (argc == 5) {
        operand_addr = strtoul(argv[4], &end, 0);
        if (*end || !operand_addr || operand_addr > UINT32_MAX - 7) return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    unsigned char hdr[20];
    if (!f) fail("open ELF");
    size_t size = fread(hdr, 1, sizeof hdr, f);
    fclose(f);
    if (size != sizeof hdr || memcmp(hdr, "\177ELF", 4) || hdr[4] != 1 ||
        hdr[5] != 1 || hdr[18] != 3 || hdr[19]) {
        errno = EINVAL;
        fail("expected little-endian i386 ELF");
    }
    child = fork();
    if (child < 0) fail("fork");
    if (!child) {
        if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) == -1) _exit(125);
        execl(argv[1], argv[1], NULL);
        _exit(126);
    }
    stop_required(wait_child());
    request(PTRACE_SETOPTIONS, (void *)(uintptr_t)PTRACE_O_EXITKILL);
    unsigned long seen = 0;
    for (unsigned long n = 0; n < 100000; ++n) {
        struct user_regs_struct regs;
        struct user_fpregs_struct before, after;
        unsigned long instruction = 0, operand = 0;
        request(PTRACE_GETREGS, &regs);
        int target = regs.rip == pc && ++seen == occurrence;
        if (target) {
            request(PTRACE_GETFPREGS, &before);
            errno = 0;
            instruction = ptrace(PTRACE_PEEKTEXT, child, (void *)pc, NULL);
            if (errno) fail("read instruction");
            if (operand_addr) {
                errno = 0;
                operand = ptrace(PTRACE_PEEKDATA, child, (void *)operand_addr, NULL);
                if (errno) fail("read operand");
            }
        }
        request(PTRACE_SINGLESTEP, NULL);
        int status = wait_child();
        stop_required(status);
        if (!target) continue;
        request(PTRACE_GETFPREGS, &after);
        request(PTRACE_CONT, NULL);
        status = wait_child();
        if (!WIFEXITED(status) || WEXITSTATUS(status)) {
            errno = EPROTO;
            fail("guest must exit normally with status zero");
        }
        child = -1;
        printf("{\"kind\":\"NATIVE_X87_PC_WITNESS\",\"pc\":\"0x%08lx\","
               "\"occurrence\":%lu,\"native_instruction_index\":%lu,", pc, seen, n);
        printf("\"instruction_prefix\":\"");
        for (int b = 0; b < 8; ++b) printf("%02lx", (instruction >> (8*b)) & 255);
        printf("\",");
        if (operand_addr) printf("\"operand_address\":\"0x%08lx\","
                                 "\"operand_bits64\":\"%016lx\",", operand_addr, operand);
        dump_fp("before", &before);
        printf(",");
        dump_fp("after", &after);
        printf(",\"native_exit\":0,\"child_reaped\":true}\n");
        return 0;
    }
    errno = ETIMEDOUT;
    fail("target not reached in 100000 instructions");
}
