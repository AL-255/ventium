/* Bare i386 guest: real x87 instructions, architectural FLDENV C1 seed.
 * Input/output are fixed little-endian records; no libc or host FP arithmetic.
 */
#include <stdint.h>

typedef struct __attribute__((packed)) { uint64_t low; uint16_t high; } X80;
typedef struct { uint32_t kind, prec, rc, ah, al, au, bh, bl, bu, seed; } Input;
typedef struct { uint32_t low, upper, high, status; } Output;

static int io(int number, int fd, void *data, unsigned size)
{
    int result;
    __asm__ volatile("int $0x80" : "=a"(result)
                     : "0"(number), "b"(fd), "c"(data), "d"(size) : "memory");
    return result;
}

static void quit(int status) __attribute__((noreturn));
static void quit(int status)
{
    __asm__ volatile("int $0x80" : : "a"(1), "b"(status) : "memory");
    __builtin_unreachable();
}

void _start(void)
{
    Input in;
    for (;;) {
        unsigned done = 0;
        while (done < sizeof(in)) {
            int count = io(3, 0, (char *)&in + done, sizeof(in) - done);
            if (count == 0) quit(done ? 91 : 0);
            if (count < 0) quit(92);
            done += count;
        }
        if (in.kind > 25 || in.prec > 2 || in.rc > 3 || in.seed > 1) quit(93);
        X80 a = { ((uint64_t)in.au << 32) | in.al, in.ah };
        X80 b = { ((uint64_t)in.bu << 32) | in.bl, in.bh };
        X80 value = { 0, 0 };
        uint64_t narrow = 0;
        uint32_t environment[7];
        uint16_t cw = 0x007f | ((in.prec == 0 ? 3 : in.prec == 1 ? 2 : 0) << 8) | (in.rc << 10);
        uint16_t status;
        __asm__ volatile("fninit; fldcw %0; fldt %1; fldt %2; fnstenv %3"
                         : : "m"(cw), "m"(b), "m"(a), "m"(environment) : "memory");
        environment[1] = (environment[1] & ~0x0200u) | (in.seed << 9);
        __asm__ volatile("fldenv %0" : : "m"(environment) : "memory");
        switch (in.kind) {
        case 0: __asm__ volatile("fsts %0" : "+m"(narrow)); break;
        case 1: __asm__ volatile("fstl %0" : "=m"(narrow)); break;
        case 2:
        case 3: __asm__ volatile(".byte 0xd8, 0xc1"); break; /* ST0 + ST1 */
        case 4: __asm__ volatile(".byte 0xd8, 0xe1"); break; /* ST0 - ST1 */
        case 5: __asm__ volatile(".byte 0xd8, 0xc9"); break;
        case 6: __asm__ volatile(".byte 0xd8, 0xf1"); break;
        case 7: __asm__ volatile("fsqrt"); break;
        case 8: __asm__ volatile("frndint"); break;
        case 9: __asm__ volatile("fldt %0" : : "m"(a)); break;
        case 10: __asm__ volatile("fld1"); break;
        case 11: __asm__ volatile("fildl %0" : : "m"(in.bl)); break;
        case 12: __asm__ volatile(".byte 0xdd, 0xd1"); break; /* FST ST1 */
        case 13: __asm__ volatile(".byte 0xdd, 0xd8"); break; /* FSTP ST0 */
        case 14: __asm__ volatile(".byte 0xd9, 0xc9"); break;
        case 15: __asm__ volatile("fchs"); break;
        case 16: __asm__ volatile("fabs"); break;
        case 17: __asm__ volatile(".byte 0xd8, 0xd1"); break;
        case 18: __asm__ volatile(".byte 0xdd, 0xe1"); break;
        case 19: __asm__ volatile("fxam"); break;
        case 20: __asm__ volatile("fprem"); break;
        case 21: __asm__ volatile("fprem1"); break;
        case 22: __asm__ volatile("fwait"); break;
        case 23: __asm__ volatile("flds %0" : : "m"(in.bl)); break;
        case 24: __asm__ volatile("fldl %0" : : "m"(b.low)); break;
        case 25: __asm__ volatile("fildll %0" : : "m"(b.low)); break;
        }
        __asm__ volatile("fnstsw %0" : "=m"(status));
        if (in.kind > 1) {
            __asm__ volatile("fstpt %0" : "=m"(value));
        } else {
            value.low = narrow;
        }
        Output out = { value.low, value.low >> 32, value.high, status };
        done = 0;
        while (done < sizeof(out)) {
            int count = io(4, 1, (char *)&out + done, sizeof(out) - done);
            if (count <= 0) quit(94);
            done += count;
        }
    }
}
