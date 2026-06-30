#pragma once
#include <stdio.h>
#include <stdint.h>
#include <sys/types.h>
struct fileTYPE {
    fileTYPE();
    ~fileTYPE();
    int opened();
    FILE      *filp;
    int        mode;
    int        type;
    void      *zip;
    __off64_t  size;
    __off64_t  offset;
    char       path[1024];
    char       name[261];
};
int  FileOpen(fileTYPE *file, const char *name, char mute = 0);
int  FileOpenEx(fileTYPE *file, const char *name, int mode, char mute = 0, int use_zip = 1);
void FileClose(fileTYPE *file);
int  FileSeek(fileTYPE *file, __off64_t offset, int origin);
int  FileSeekLBA(fileTYPE *file, uint32_t offset);
int  FileReadAdv(fileTYPE *file, void *pBuffer, int length, int failres = 0);
int  FileReadSec(fileTYPE *file, void *pBuffer);
int  FileWriteAdv(fileTYPE *file, void *pBuffer, int length, int failres = 0);
int  FileWriteSec(fileTYPE *file, void *pBuffer);
int  FileCanWrite(const char *name);
int  FileSaveConfig(const char *name, void *pBuffer, int size);
int  FileLoadConfig(const char *name, void *pBuffer, int size);
const char *getFullPath(const char *name);
