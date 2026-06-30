#pragma once
#include <stdint.h>
extern uint8_t rstval;
void hexdump(void *data, uint16_t size, uint16_t offset = 0);
