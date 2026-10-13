/* Real x87 instruction oracle. FRSTOR seeds directed architectural operands;
 * no emulator helper, debugger state write, or workload snapshot is involved.
 * Non-waiting FNSAVE observes even unmasked exceptions without a second trap.
 */
#include <stdint.h>
typedef struct { uint32_t cw, sw, tag, hi, lo, upper, kind, pad; } Input;
typedef struct { uint32_t lo, upper, hi, sw; } Output;
static int io(int n, int fd, void *p, unsigned len) {
    int r;
    __asm__ volatile("int $0x80" : "=a"(r) : "0"(n), "b"(fd), "c"(p), "d"(len) : "memory");
    return r;
}
static void quit(int code) __attribute__((noreturn));
static void quit(int code) {
    __asm__ volatile("int $0x80" : : "a"(1), "b"(code) : "memory");
    __builtin_unreachable();
}
void _start(void) {
    Input in;
    for (;;) {
        unsigned done=0;
        while (done<sizeof(in)) {
            int n=io(3,0,(char *)&in+done,sizeof(in)-done);
            if (!n) quit(done ? 91 : 0);
            if (n<0) quit(92);
            done+=n;
        }
        if (in.kind>3) quit(93);
        uint32_t env[27]={0};
        env[0]=in.cw; env[1]=in.sw; env[2]=in.tag;
        for (unsigned i=0;i<8;i++) {
            unsigned char *p=(unsigned char *)env+28+10*i;
            for (unsigned k=0;k<10;k++) p[k]=0;
            p[7]=0x80; p[8]=0xff; p[9]=0x3f;
        }
        env[7]=in.lo; env[8]=in.upper;
        ((uint16_t *)env)[18]=(uint16_t)in.hi;
        uint64_t store=0;
        __asm__ volatile("fninit; frstor %0" : : "m"(env) : "memory");
        switch (in.kind) {
        case 0: __asm__ volatile("frndint"); break;
        case 1: __asm__ volatile("fistpll %0" : "=m"(store)); break;
        case 2: __asm__ volatile("fsts %0" : "+m"(store)); break;
        case 3: __asm__ volatile("fstl %0" : "=m"(store)); break;
        }
        __asm__ volatile("fnsave %0" : "=m"(env) : : "memory");
        Output out={env[7],env[8],((uint16_t *)env)[18],env[1]&0xffff};
        if (in.kind) { out.lo=store; out.upper=store>>32; out.hi=0; }
        done=0;
        while (done<sizeof(out)) {
            int n=io(4,1,(char *)&out+done,sizeof(out)-done);
            if (n<=0) quit(94);
            done+=n;
        }
    }
}
