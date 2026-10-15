/* No save/restore or FLDCW between FPREM and FADD: observe internal PC leaks. */
#include <stdint.h>
typedef struct { uint32_t id, kind, cw, sw, ah, al, au, bh, bl, bu; } Input;
typedef struct {
    uint32_t id;
    uint16_t cw, rem_sw, add_sw, reserved;
    unsigned char rem[10], sum[10];
} Output;
_Static_assert(sizeof(Output)==32, "output layout");
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
        if (in.kind>1 || (in.cw&0x3f)!=0x3f) quit(93);
        uint32_t state[27]={0};
        state[0]=in.cw; state[1]=in.sw;
        for (unsigned i=0;i<8;i++) {
            unsigned char *p=(unsigned char *)state+28+10*i;
            p[7]=0x80; p[8]=0xff+i; p[9]=0x3f+(i!=0);
        }
        unsigned char *p=(unsigned char *)state+28;
        *(uint32_t *)(p+0)=in.al; *(uint32_t *)(p+4)=in.au; *(uint16_t *)(p+8)=in.ah;
        *(uint32_t *)(p+10)=in.bl; *(uint32_t *)(p+14)=in.bu; *(uint16_t *)(p+18)=in.bh;
        Output out={0}; out.id=in.id;
        __asm__ volatile("fninit; frstor %0" : : "m"(state) : "memory");
        if (in.kind) __asm__ volatile("fprem1");
        else __asm__ volatile("fprem");
        __asm__ volatile("fnstcw %0; fnstsw %1; fstpt %2; fldt %2; fadd %%st(1), %%st; fnstsw %3; fstpt %4"
            : "=m"(out.cw), "=m"(out.rem_sw), "=m"(out.rem), "=m"(out.add_sw), "=m"(out.sum)
            : : "memory");
        __asm__ volatile("fninit");
        done=0;
        while (done<sizeof(out)) {
            int n=io(4,1,(char *)&out+done,sizeof(out)-done);
            if (n<=0) quit(94);
            done+=n;
        }
    }
}
