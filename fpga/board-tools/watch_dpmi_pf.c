/* Post-fault diagnostic for the pinned October-7 CWSDPMI layout.
 * Not a workload fix or acceptance run. No guest writes, STEP, breakpoint,
 * comparator, clock change or reset. A manual HALT is requested only AFTER
 * the guest publishes vector14 and a complete CPL3 fault frame in DDR.
 * The launcher MUST validate the exact image, guest inputs and reserved DDR.
 * The sampled frame is a trigger, not an atomic architectural-state claim.
 */
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

enum { IDENT=0, FREEZE=0x90, RET_LO=0x120, RET_HI=0x130,
       EXEC=0x280, CAP=0x2c0, VECTOR=0x3166c, FRAME=0x2ff4a };
static void barrier(void) {
#if defined(__aarch64__)
    __asm__ volatile("dmb sy" ::: "memory");
#else
    __sync_synchronize();
#endif
}
static uint32_t rd(volatile uint8_t *p, size_t off) {
    assert(!(off & 3));
    return *(volatile uint32_t *)(p+off);
}
/* The frame is two-byte aligned; issue ONLY aligned DDR loads, then shift
 * private values. In particular, never perform unaligned Device loads. */
static uint32_t unaligned_word(volatile uint8_t *p, size_t off) {
    uint32_t lo=rd(p,off & ~(size_t)3);
    unsigned shift=(unsigned)(off & 3)*8;
    return shift ? (lo>>shift)|(rd(p,(off & ~(size_t)3)+4)<<(32-shift)) : lo;
}
static uint64_t ns(void) {
    struct timespec t;
    if(clock_gettime(CLOCK_MONOTONIC,&t)) { perror("clock_gettime"); exit(2); }
    return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
}
static bool frame_ok(const uint32_t f[6]) {
    return f[0]<=31 && f[1]!=0 && f[2]==0xa7 &&
           (f[3]&2) && !(f[3]&0x20000) && f[5]==0xaf;
}
static void frame_read(volatile uint8_t *ram,uint32_t f[6]) {
    for(unsigned i=0;i<6;i++) f[i]=unaligned_word(ram,FRAME+4*i);
}
static bool running(volatile uint8_t *ctrl) {
    return rd(ctrl,IDENT)==0xa0486501 && rd(ctrl,CAP)==0x56450005 &&
           !(rd(ctrl,EXEC)&0x107) && !(rd(ctrl,FREEZE)&0x80000000);
}
static uint64_t retires(volatile uint8_t *ctrl) {
    for(unsigned tries=0;tries<8;tries++) {
        uint32_t hi=rd(ctrl,RET_HI),lo=rd(ctrl,RET_LO);
        if(hi==rd(ctrl,RET_HI)) return ((uint64_t)hi<<32)|lo;
    }
    fprintf(stderr,"unstable retirement counter\n");exit(2);
}
static int selftest(void) {
    _Alignas(16) uint8_t bytes[48]={0};
    const uint32_t good[6]={4,0x108,0xa7,0x3206,0xe0810,0xaf};
    memcpy(bytes+2,good,sizeof(good));
    for(unsigned i=0;i<6;i++) assert(unaligned_word(bytes,2+i*4)==good[i]);
    uint32_t f[6];memcpy(f,good,sizeof(f));assert(frame_ok(f));
    f[0]=0xece08;assert(!frame_ok(f)); /* stripped-error/IRQ/stale frame */
    memcpy(f,good,sizeof(f));f[2]=0x87;assert(!frame_ok(f));
    memcpy(f,good,sizeof(f));f[5]=0x20;assert(!frame_ok(f));
    memcpy(f,good,sizeof(f));f[3]&=~2u;assert(!frame_ok(f));
    memcpy(f,good,sizeof(f));f[3]|=0x20000;assert(!frame_ok(f));
    memcpy(f,good,sizeof(f));f[1]=0;assert(!frame_ok(f));
    f[0]=0;f[1]=0x59682;f[3]=0x3246;assert(frame_ok(f));
    _Alignas(16) uint8_t ctrl[0x1000]={0};
    *(uint32_t *)(ctrl+IDENT)=0xa0486501;
    *(uint32_t *)(ctrl+CAP)=0x56450005;
    assert(running(ctrl));
    const uint32_t masks[]={1,2,4,0x100};
    for(unsigned i=0;i<4;i++) {
        *(uint32_t *)(ctrl+EXEC)=masks[i];assert(!running(ctrl));
    }
    *(uint32_t *)(ctrl+EXEC)=0;*(uint32_t *)(ctrl+FREEZE)=0x80000000;
    assert(!running(ctrl));
    puts("DPMI-PF-WATCH-SELFTEST-OK; parser/UV guards only, no hardware acceptance");
    return 0;
}
int main(int argc,char **argv) {
    if(argc==2 && !strcmp(argv[1],"--self-test"))return selftest();
    if(argc!=2 || strcmp(argv[1],"--post-fault-halt-pinned-oct07") || geteuid()) {
        fprintf(stderr,"requires root and --post-fault-halt-pinned-oct07; or --self-test\n");return 2;
    }
    int fd=open("/dev/mem",O_RDWR|O_SYNC);
    if(fd<0){perror("/dev/mem");return 2;}
    volatile uint8_t *ctrl=mmap(NULL,0x10000,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0xa0000000);
    volatile uint8_t *ram=mmap(NULL,0x1000000,PROT_READ,MAP_SHARED,fd,0x60000000);
    if(ctrl==MAP_FAILED || ram==MAP_FAILED){perror("mmap");return 2;}
    uint64_t start=ns(),loops=0,last_ret=0;
    bool armed=false,saw_clear=false;
    int result=1;
    while(true) {
        if(!(loops++ & 4095)) {
            if(!running(ctrl)){fputs("UV running guard failed\n",stderr);break;}
            uint64_t count=retires(ctrl);
            if(count<last_ret){fputs("counter reset\n",stderr);break;}
            last_ret=count;
            if(!armed && count>=75000000) {
                armed=true;saw_clear=false;
                printf("{\"event\":\"armed\",\"primary_retirements\":%"PRIu64",\"time_ns\":%"PRIu64"}\n",count,ns());fflush(stdout);
            }
            if(ns()-start>UINT64_C(300000000000)){fputs("watch timeout\n",stderr);break;}
        }
        if(!armed)continue;
        unsigned vector=rd(ram,VECTOR)&0xffff;
        if(vector!=14){saw_clear=true;continue;}
        if(!saw_clear)continue;
        uint32_t f[6],g[6];frame_read(ram,f);barrier();frame_read(ram,g);
        if(!frame_ok(f) || memcmp(f,g,sizeof(f)) || (rd(ram,VECTOR)&0xffff)!=14)continue;
        if(!running(ctrl)){fputs("pre-HALT UV guard failed\n",stderr);break;}
        uint64_t matched=ns();
        *(volatile uint32_t *)(ctrl+EXEC)=1; /* sole control write: manual HALT */
        barrier();
        if(rd(ctrl,IDENT)!=0xa0486501){fputs("ordered IDENT failed\n",stderr);break;}
        while(!(rd(ctrl,EXEC)&4) && ns()-matched<UINT64_C(5000000000)) {}
        uint32_t exec=rd(ctrl,EXEC),freeze=rd(ctrl,FREEZE);
        printf("{\"event\":\"post_fault_halt\",\"time_ns\":%"PRIu64",\"ack_ns\":%"PRIu64",\"loops\":%"PRIu64",\"frame\":[%u,%u,%u,%u,%u,%u],\"exec_control\":%u,\"freeze\":%u}\n",
               matched,ns(),loops,f[0],f[1],f[2],f[3],f[4],f[5],exec,freeze);
        result=((exec&0x107)==5 && !(freeze&0x80000000)) ? 0:1;
        break;
    }
    munmap((void *)ram,0x1000000);munmap((void *)ctrl,0x10000);close(fd);
    return result;
}
