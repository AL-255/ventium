#pragma once
#include <stdint.h>
#define UIO_DMA_WRITE 0x61
#define UIO_DMA_READ  0x62
#define UIO_DMA_SDIO  0x63
uint32_t user_io_status_get(const char *opt, int ex = 0);
void     user_io_status_set(const char *opt, uint32_t value, int ex = 0);
char    *user_io_get_core_name(int orig = 0);
char    *user_io_make_filepath(const char *path, const char *filename);
char     is_x86();
char     is_pcxt();
char     is_minimig();
#define HomeDir(x) user_io_get_core_path(x)
char    *user_io_get_core_path(const char *suffix = "");
