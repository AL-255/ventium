// SPDX-License-Identifier: Apache-2.0
// Narrow, single-owner AArch64 MMIO backend for ven_ps2_mailbox ABI 1.
// No guest RAM, clock, reset, IRQ or execution-control access.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#if !defined(__aarch64__) && !defined(VEN_PS2_MMIO_TEST)
#error "Physical PS/2 MMIO backend requires AArch64"
#endif
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "PS/2 register ABI requires little endian"
#endif

struct ven_ps2_mmio {
    volatile uint8_t *mapping;
    size_t size;
    int memory_fd, lock_fd;
    pid_t owner;
};

static void barrier(void)
{
#ifdef VEN_PS2_MMIO_TEST
    __sync_synchronize(); // Host fixture only; never an ARM ordering proof.
#else
    __asm__ volatile("dsb sy" ::: "memory");
#endif
}

static uint32_t read_word(struct ven_ps2_mmio *m, unsigned index)
{
    barrier();
    uint32_t value = *(volatile uint32_t *)(m->mapping + 0x400 + 16 * index);
    barrier();
    return value;
}

// No explicit LOCK_UN: closing a forked child's copy must not unlock its parent.
void ven_ps2_mmio_close(struct ven_ps2_mmio *m)
{
    if (!m) return;
    if (m->mapping != MAP_FAILED) munmap((void *)m->mapping, m->size);
    if (m->memory_fd >= 0) close(m->memory_fd);
    if (m->lock_fd >= 0) close(m->lock_fd);
    free(m);
}

static struct ven_ps2_mmio *open_backend(const char *memory, const char *lock,
                                        off_t offset, int fixture)
{
    struct ven_ps2_mmio *m = calloc(1, sizeof(*m));
    if (!m) return NULL;
    m->mapping = MAP_FAILED;
    m->memory_fd = m->lock_fd = -1;
    m->owner = getpid();
    long page = sysconf(_SC_PAGESIZE);
    if (page < 0x1000 || offset % page) { errno = EINVAL; goto fail; }
    m->size = (size_t)page;
    m->lock_fd = open(lock, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (m->lock_fd < 0) goto fail;
    struct stat st;
    if (fstat(m->lock_fd, &st)) goto fail;
    if (!S_ISREG(st.st_mode) || st.st_uid != geteuid() || st.st_nlink != 1) {
        errno = EPERM;
        goto fail;
    }
    if (flock(m->lock_fd, LOCK_EX | LOCK_NB)) goto fail;
    m->memory_fd = open(memory, O_RDWR | O_SYNC | O_CLOEXEC | O_NOFOLLOW);
    if (m->memory_fd < 0) goto fail;
    if (fstat(m->memory_fd, &st)) goto fail;
    if (fixture ? (!S_ISREG(st.st_mode) || st.st_size < page) : !S_ISCHR(st.st_mode)) {
        errno = EINVAL;
        goto fail;
    }
    m->mapping = mmap(NULL, m->size, PROT_READ | PROT_WRITE, MAP_SHARED,
                      m->memory_fd, offset);
    if (m->mapping == MAP_FAILED) goto fail;
    if (read_word(m, 0) != UINT32_C(0x50533201)) { errno = ENODEV; goto fail; }
    return m;
fail:;
    int saved = errno;
    ven_ps2_mmio_close(m);
    errno = saved;
    return NULL;
}

unsigned ven_ps2_mmio_fixture_build(void)
{
#ifdef VEN_PS2_MMIO_TEST
    return 1;
#else
    return 0;
#endif
}

struct ven_ps2_mmio *ven_ps2_mmio_open(void)
{
#ifdef VEN_PS2_MMIO_TEST
    errno = ENOTSUP; // A host fixture build cannot open physical MMIO.
    return NULL;
#else
    return open_backend("/dev/mem", "/run/lock/ventium-ps2-mouse.lock",
                        (off_t)UINT32_C(0xa0000000), 0);
#endif
}

#ifdef VEN_PS2_MMIO_TEST
// Test-only export; entirely absent from the deployed shared library.
struct ven_ps2_mmio *ven_ps2_mmio_open_fixture(const char *memory, const char *lock)
{
    return open_backend(memory, lock, 0, 1);
}
#endif

static int owned(struct ven_ps2_mmio *m)
{
    if (!m || m->owner != getpid()) { errno = EPERM; return 0; }
    return 1;
}

int ven_ps2_mmio_read(struct ven_ps2_mmio *m, unsigned index, uint32_t *value)
{
    if (!owned(m)) return -1;
    if (!value || !(index == 0 || index == 1 || index == 2 || index == 5 ||
                    index == 7 || index == 8)) { errno = EINVAL; return -1; }
    *value = read_word(m, index);
    return 0;
}

int ven_ps2_mmio_write(struct ven_ps2_mmio *m, unsigned index, uint32_t value)
{
    if (!owned(m)) return -1;
    if (!(index == 3 || index == 4 || index == 6 || index == 9 || index == 10) ||
        (index == 4 && value > 255) || (index == 10 && value > 3)) {
        errno = EINVAL;
        return -1;
    }
    barrier();
    *(volatile uint32_t *)(m->mapping + 0x400 + 16 * index) = value;
    barrier();
    // An ordered read of the same peripheral follows every store. It does not
    // acknowledge delivery: the policy still confirms the sequence/event.
    (void)read_word(m, 1);
    return 0;
}
