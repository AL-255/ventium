#pragma once
#include <stdint.h>
typedef struct _chd_file chd_file;
struct fileTYPE;
int  mister_load_chd(const char *filename, struct fileTYPE *f);
int  mister_chd_read_sector(chd_file *chd_f, uint32_t lba, uint32_t offset, uint32_t size, void *buffer, int *hunknum, uint8_t *hunkbuf);
