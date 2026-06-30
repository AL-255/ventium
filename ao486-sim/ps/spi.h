#pragma once
#include <stdint.h>
void EnableIO();
void DisableIO();
uint8_t  spi_b(uint8_t parm);
uint16_t spi_w(uint16_t word);
void     spi32_b(uint32_t parm);
uint32_t spi32_w(uint32_t parm);
#define spi8(x) spi_b(x)
#include "fpga_io.h"
