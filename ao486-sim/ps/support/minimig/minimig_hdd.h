#pragma once
#include <stdint.h>
#define RDB_MAGIC 0x4B534452
struct RigidDiskBlock {
    uint32_t rdb_ID; uint32_t rdb_Summedlongs; int32_t rdb_ChkSum; uint32_t rdb_HostID;
    uint32_t rdb_BlockBytes; uint32_t rdb_Flags; uint32_t rdb_BadBlockList; uint32_t rdb_PartitionList;
    uint32_t rdb_FileSysHeaderList; uint32_t rdb_DriveInit; uint32_t rdb_Reserved1[6];
    uint32_t rdb_Cylinders; uint32_t rdb_Sectors; uint32_t rdb_Heads; uint32_t rdb_Interleave;
    uint32_t rdb_Park; uint32_t rdb_Reserved2[3]; uint32_t rdb_WritePreComp; uint32_t rdb_ReducedWrite;
    uint32_t rdb_StepRate; uint32_t rdb_Reserved3[5]; uint32_t rdb_RDBBlocksLo; uint32_t rdb_RDBBlocksHi;
    uint32_t rdb_LoCylinder; uint32_t rdb_HiCylinder; uint32_t rdb_CylBlocks; uint32_t rdb_AutoParkSeconds;
    uint32_t rdb_HighRDSKBlock; uint32_t rdb_Reserved4; char rdb_DiskVendor[8]; char rdb_DiskProduct[16];
    char rdb_DiskRevision[4]; char rdb_ControllerVendor[8]; char rdb_ControllerProduct[16];
    char rdb_ControllerRevision[4]; uint32_t rdb_Reserved5[10];
} __attribute__((packed));
struct DosEnvec {
    uint32_t de_TableSize, de_SizeBlock, de_SecOrg, de_Surfaces, de_SectorPerBlock;
    uint32_t de_BlocksPerTrack, de_Reserved, de_PreAlloc, de_Interleave, de_LowCyl;
    uint32_t de_HighCyl, de_NumBuffers, de_BufMemType, de_MaxTransfer, de_Mask;
    int32_t  de_BootPri; uint32_t de_DosType, de_Baud, de_Control, de_BootBlocks;
} __attribute__((packed));
struct PartitionBlock {
    uint32_t pb_ID, pb_Summedlongs; int32_t pb_ChkSum; uint32_t pb_HostID, pb_Next, pb_Flags;
    uint32_t pb_Reserved1[2], pb_DevFlags; char pb_DriveName[32]; uint32_t pb_Reserved2[15];
    struct DosEnvec pb_Environment; uint32_t pb_EReserved[12];
} __attribute__((packed));
