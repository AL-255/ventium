#pragma once
typedef struct {
    unsigned char ide_cfg;
    struct { unsigned char cfg; char filename[1024]; } hardfile[4];
} mm_configTYPE;
extern mm_configTYPE minimig_config;
