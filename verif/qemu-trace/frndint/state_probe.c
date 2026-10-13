/* Full saved-state instruction probe. Inputs are directed fixtures, not
 * workload snapshots. kind=1 checks PC restoration with a following FADD. */
#include <stdint.h>
typedef struct { uint32_t cw, sw, tag, hi, lo, upper, kind, pad; } Input;
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
        if (in.kind>1) quit(93);
        uint32_t env[27]={0};
        env[0]=in.cw; env[1]=in.sw; env[2]=in.tag;
        for (unsigned i=0;i<8;i++) {
            unsigned char *p=(unsigned char *)env+28+10*i;
            p[7]=0x80; p[8]=0xff+i; p[9]=0x3f+(i!=0);
        }
        env[7]=in.lo; env[8]=in.upper;
        ((uint16_t *)env)[18]=(uint16_t)in.hi;
        __asm__ volatile("fninit; frstor %0" : : "m"(env) : "memory");
        __asm__ volatile("frndint");
        if (in.kind) __asm__ volatile("fadd %st(1), %st");
        __asm__ volatile("fnsave %0" : "=m"(env) : : "memory");
        done=0;
        while (done<sizeof(env)) {
            int n=io(4,1,(char *)env+done,sizeof(env)-done);
            if (n<=0) quit(94);
            done+=n;
        }
    }
}
