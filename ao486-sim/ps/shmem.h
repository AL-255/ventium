#pragma once
#include <stdint.h>
#define SHMEM_ADDR 0x30000000
void *shmem_map(uint32_t address, uint32_t size);
int   shmem_unmap(void* map, uint32_t size);
int   shmem_put(uint32_t address, uint32_t size, void *buf);
int   shmem_get(uint32_t address, uint32_t size, void *buf);
