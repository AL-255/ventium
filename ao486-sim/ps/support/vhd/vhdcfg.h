#pragma once
struct drive_t;
typedef enum { VHD_NOERROR = 0, VHD_ERROR = 1 } vhd_error;
vhd_error parse_vhd_config(drive_t *drive);
