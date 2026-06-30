#pragma once
#include <stdint.h>
uint16_t fpga_spi_fast(uint16_t word);
void fpga_spi_fast_block_write(const uint16_t *buf, uint32_t length);
void fpga_spi_fast_block_read(uint16_t *buf, uint32_t length);
void fpga_spi_fast_block_write_8(const uint8_t *buf, uint32_t length);
void fpga_spi_fast_block_read_8(uint8_t *buf, uint32_t length);
void fpga_spi_fast_block_write_be(const uint16_t *buf, uint32_t length);
void fpga_spi_fast_block_read_be(uint16_t *buf, uint32_t length);
