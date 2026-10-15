/* Single-instruction exception probe. FRSTOR creates directed operands;
 * FNSAVE observes an unmasked exception without executing a waiting opcode.
 * No application snapshots, signal recovery or patched guest instructions. */
#include <stdint.h>
typedef struct { uint32_t cw, sw, tag, op, alo, ahi, ae, blo, bhi, be; } Input;
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
        if (in.op>1) quit(93);
        uint32_t env[27]={0};
        env[0]=in.cw; env[1]=in.sw; env[2]=in.tag;
        for (unsigned i=0;i<8;i++) {
            unsigned char *p=(unsigned char *)env+28+10*i;
            p[7]=0x80; p[8]=0xff+i; p[9]=0x3f+(i!=0);
        }
        env[7]=in.alo; env[8]=in.ahi;
        ((uint16_t *)env)[18]=in.ae;
        ((uint16_t *)env)[19]=in.blo;
        ((uint16_t *)env)[20]=in.blo>>16;
        ((uint16_t *)env)[21]=in.bhi;
        ((uint16_t *)env)[22]=in.bhi>>16;
        ((uint16_t *)env)[23]=in.be;
        __asm__ volatile("fninit; frstor %0" : : "m"(env) : "memory");
        if (in.op) __asm__ volatile("fprem1");
        else __asm__ volatile("fprem");
        __asm__ volatile("fnsave %0" : "=m"(env) : : "memory");
        done=0;
        while (done<sizeof(env)) {
            int n=io(4,1,(char *)env+done,sizeof(env)-done);
            if (n<=0) quit(94);
            done+=n;
        }
    }
}
