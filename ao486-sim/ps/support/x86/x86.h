#ifndef X86_H
#define X86_H

void x86_init();
void x86_poll(int only_ide);
void x86_ide_set();

void x86_set_image(int num, char *filename);
// Host-only disk rebind for an already-running FPGA guest.  It performs no
// guest RAM, CMOS, reset, or IDE-management write.
int x86_attach_hdd0(const char *filename);
// Attach mode intentionally services only IDE0; other process-local backends
// have not been reconstructed.
void x86_poll_ide0();
const char* x86_get_image_name(int num);
const char* x86_get_image_path(int num);

void x86_config_load();
void x86_config_save();
void x86_set_fdd_boot(uint32_t boot);

#endif
